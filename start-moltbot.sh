#!/bin/bash
# Startup script for Moltbot in Cloudflare Sandbox
#
# Persistence strategy:
# - Workspace (/root/clawd): Symlinked directly to R2 for immediate persistence
# - Config (/root/.clawdbot): Backup/restore from R2 (modified by env vars on boot)
#
# Custom hooks:
# - /data/moltbot/hooks/post-boot.sh: Runs after setup, before gateway starts

set -e

# ============================================================
# EARLY EXIT CHECK
# ============================================================
if pgrep -f "clawdbot gateway" > /dev/null 2>&1; then
    echo "Moltbot gateway is already running, exiting."
    exit 0
fi

# ============================================================
# PATHS
# ============================================================
CONFIG_DIR="/root/.clawdbot"
CONFIG_FILE="$CONFIG_DIR/clawdbot.json"
TEMPLATE_DIR="/root/.clawdbot-templates"
TEMPLATE_FILE="$TEMPLATE_DIR/moltbot.json.template"
R2_MOUNT="/data/moltbot"
WORKSPACE_LOCAL="/root/clawd"
WORKSPACE_R2="$R2_MOUNT/clawd"

echo "=== Moltbot Startup ==="
echo "Config: $CONFIG_DIR"
echo "R2 Mount: $R2_MOUNT"

# Create config directory
mkdir -p "$CONFIG_DIR"

# ============================================================
# WORKSPACE PERSISTENCE (symlink to R2)
# ============================================================
# The workspace is symlinked directly to R2 so all writes persist immediately.
# No backup/restore needed - files are always on R2.

if [ -d "$R2_MOUNT" ]; then
    echo "Setting up workspace persistence..."
    
    # Create workspace on R2 if it doesn't exist
    if [ ! -d "$WORKSPACE_R2" ]; then
        echo "Creating workspace on R2: $WORKSPACE_R2"
        mkdir -p "$WORKSPACE_R2"
    fi
    
    # Handle existing local workspace (migrate to R2 if needed)
    if [ -d "$WORKSPACE_LOCAL" ] && [ ! -L "$WORKSPACE_LOCAL" ]; then
        echo "Migrating existing workspace to R2..."
        # Use --ignore-existing to not overwrite R2 data
        if command -v rsync &> /dev/null; then
            rsync -a --ignore-existing "$WORKSPACE_LOCAL/" "$WORKSPACE_R2/" 2>/dev/null || true
        else
            cp -an "$WORKSPACE_LOCAL/." "$WORKSPACE_R2/" 2>/dev/null || true
        fi
        rm -rf "$WORKSPACE_LOCAL"
        echo "Migration complete"
    fi
    
    # Create or fix symlink
    if [ -L "$WORKSPACE_LOCAL" ]; then
        CURRENT_TARGET=$(readlink "$WORKSPACE_LOCAL")
        if [ "$CURRENT_TARGET" != "$WORKSPACE_R2" ]; then
            echo "Fixing symlink (was: $CURRENT_TARGET)"
            rm "$WORKSPACE_LOCAL"
            ln -sf "$WORKSPACE_R2" "$WORKSPACE_LOCAL"
        fi
    else
        # Remove any stale file/broken symlink
        rm -f "$WORKSPACE_LOCAL" 2>/dev/null || true
        ln -sf "$WORKSPACE_R2" "$WORKSPACE_LOCAL"
    fi
    
    echo "Workspace: $WORKSPACE_LOCAL -> $WORKSPACE_R2"
else
    echo "WARNING: R2 not mounted at $R2_MOUNT"
    echo "Workspace will be ephemeral (data lost on restart)"
    mkdir -p "$WORKSPACE_LOCAL"
fi

# ============================================================
# CONFIG RESTORE FROM R2
# ============================================================
# Config is backed up to R2 but restored to local filesystem because
# env vars modify it on each boot.

CONFIG_BACKUP="$R2_MOUNT/clawdbot"

restore_config() {
    if [ -f "$CONFIG_BACKUP/clawdbot.json" ]; then
        echo "Restoring config from R2..."
        cp -a "$CONFIG_BACKUP/." "$CONFIG_DIR/"
        echo "Config restored"
        return 0
    fi
    return 1
}

if [ -d "$R2_MOUNT" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        # No local config, try to restore from R2
        restore_config || echo "No R2 backup found"
    else
        # Local config exists - check if R2 is newer
        R2_SYNC="$R2_MOUNT/.last-sync"
        LOCAL_SYNC="$CONFIG_DIR/.last-sync"
        if [ -f "$R2_SYNC" ]; then
            if [ ! -f "$LOCAL_SYNC" ]; then
                restore_config
            else
                R2_TIME=$(date -d "$(cat "$R2_SYNC")" +%s 2>/dev/null || echo "0")
                LOCAL_TIME=$(date -d "$(cat "$LOCAL_SYNC")" +%s 2>/dev/null || echo "0")
                if [ "$R2_TIME" -gt "$LOCAL_TIME" ]; then
                    restore_config
                fi
            fi
        fi
    fi
fi

# Create config from template if still missing
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Initializing config from template..."
    if [ -f "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "$CONFIG_FILE"
    else
        cat > "$CONFIG_FILE" << 'EOFCONFIG'
{
  "agents": {
    "defaults": {
      "workspace": "/root/clawd"
    },
    "list": [
      {
        "id": "main",
        "workspace": "/root/clawd"
      }
    ]
  },
  "gateway": {
    "port": 18789,
    "mode": "local"
  }
}
EOFCONFIG
    fi
fi

# ============================================================
# UPDATE CONFIG FROM ENVIRONMENT VARIABLES
# ============================================================
node << 'EOFNODE'
const fs = require('fs');

const configPath = '/root/.clawdbot/clawdbot.json';
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

// Ensure nested objects exist
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Clean up any broken anthropic provider config from previous runs
if (config.models?.providers?.anthropic?.models) {
    const hasInvalidModels = config.models.providers.anthropic.models.some(m => !m.name);
    if (hasInvalidModels) {
        console.log('Removing broken anthropic provider config');
        delete config.models.providers.anthropic;
    }
}

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

// Set gateway token if provided
if (process.env.CLAWDBOT_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.CLAWDBOT_GATEWAY_TOKEN;
}

// Allow insecure auth for dev mode
if (process.env.CLAWDBOT_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Telegram configuration
if (process.env.TELEGRAM_BOT_TOKEN) {
    config.channels.telegram = config.channels.telegram || {};
    config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
    config.channels.telegram.enabled = true;
    config.channels.telegram.dm = config.channels.telegram.dm || {};
    config.channels.telegram.dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
}

// Discord configuration
if (process.env.DISCORD_BOT_TOKEN) {
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
    config.channels.discord.enabled = true;
    config.channels.discord.dm = config.channels.discord.dm || {};
    config.channels.discord.dm.policy = process.env.DISCORD_DM_POLICY || 'pairing';
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = config.channels.slack || {};
    config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
    config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
    config.channels.slack.enabled = true;
}

// Base URL override (e.g., for Cloudflare AI Gateway)
const baseUrl = (process.env.AI_GATEWAY_BASE_URL || process.env.ANTHROPIC_BASE_URL || '').replace(/\/+$/, '');
const isOpenAI = baseUrl.endsWith('/openai');

if (isOpenAI) {
    console.log('Configuring OpenAI provider with base URL:', baseUrl);
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    config.models.providers.openai = {
        baseUrl: baseUrl,
        api: 'openai-responses',
        models: [
            { id: 'gpt-5.2', name: 'GPT-5.2', contextWindow: 200000 },
            { id: 'gpt-5', name: 'GPT-5', contextWindow: 200000 },
            { id: 'gpt-4.5-preview', name: 'GPT-4.5 Preview', contextWindow: 128000 },
        ]
    };
    config.agents.defaults.models = config.agents.defaults.models || {};
    config.agents.defaults.models['openai/gpt-5.2'] = { alias: 'GPT-5.2' };
    config.agents.defaults.models['openai/gpt-5'] = { alias: 'GPT-5' };
    config.agents.defaults.models['openai/gpt-4.5-preview'] = { alias: 'GPT-4.5' };
    config.agents.defaults.model.primary = 'openai/gpt-5.2';
} else if (baseUrl) {
    console.log('Configuring Anthropic provider with base URL:', baseUrl);
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    const providerConfig = {
        baseUrl: baseUrl,
        api: 'anthropic-messages',
        models: [
            { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', contextWindow: 200000 },
            { id: 'claude-sonnet-4-5-20250929', name: 'Claude Sonnet 4.5', contextWindow: 200000 },
            { id: 'claude-haiku-4-5-20251001', name: 'Claude Haiku 4.5', contextWindow: 200000 },
        ]
    };
    if (process.env.ANTHROPIC_API_KEY) {
        providerConfig.apiKey = process.env.ANTHROPIC_API_KEY;
    }
    config.models.providers.anthropic = providerConfig;
    config.agents.defaults.models = config.agents.defaults.models || {};
    config.agents.defaults.models['anthropic/claude-opus-4-5-20251101'] = { alias: 'Opus 4.5' };
    config.agents.defaults.models['anthropic/claude-sonnet-4-5-20250929'] = { alias: 'Sonnet 4.5' };
    config.agents.defaults.models['anthropic/claude-haiku-4-5-20251001'] = { alias: 'Haiku 4.5' };
    config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5-20251101';
} else {
    config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5';
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Config updated');
EOFNODE

# ============================================================
# CUSTOM POST-BOOT HOOK
# ============================================================
# Run custom scripts from R2 without needing to redeploy.
# Create /data/moltbot/hooks/post-boot.sh on R2 to customize.

POST_BOOT_HOOK="$R2_MOUNT/hooks/post-boot.sh"
if [ -f "$POST_BOOT_HOOK" ]; then
    echo "Running post-boot hook: $POST_BOOT_HOOK"
    source "$POST_BOOT_HOOK"
fi

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting Moltbot Gateway on port 18789..."

# Clean up stale lock files
rm -f /tmp/clawdbot-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

BIND_MODE="lan"

if [ -n "$CLAWDBOT_GATEWAY_TOKEN" ]; then
    echo "Auth: token"
    exec clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE" --token "$CLAWDBOT_GATEWAY_TOKEN"
else
    echo "Auth: device pairing"
    exec clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE"
fi
