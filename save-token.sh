#!/bin/bash
# Save Token Helper Script
# Quick way to save tokens for use in scripts

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_DIR="/tmp/donut-tokens"
mkdir -p "$TOKEN_DIR"

show_usage() {
    cat << EOF
🔑 Save Token Helper

Usage:
    $0 <service> <token>
    $0 --list
    $0 --export-env

Services:
    claude          Claude API token
    marketplace     Marketplace API token
    nextauth        NextAuth session token
    google-oauth    Google OAuth credentials (JSON)

Examples:
    # Save token
    $0 claude sk-ant-api03-xxx

    # List saved tokens
    $0 --list

    # Export as environment variables
    source <($0 --export-env)

    # Read from stdin
    echo "sk-ant-api03-xxx" | $0 claude -

Token Storage:
    $TOKEN_DIR/<service>.token

EOF
}

save_token() {
    local service="$1"
    local token="$2"

    if [ "$token" = "-" ]; then
        # Read from stdin
        token=$(cat)
    fi

    local token_file="$TOKEN_DIR/$service.token"
    echo "$token" > "$token_file"
    chmod 600 "$token_file"

    echo "✅ Token saved: $token_file"
    echo "   Service: $service"
    echo "   Token: ${token:0:8}...${token: -8}"
    echo ""
    echo "💡 Use in scripts:"
    echo "   export ${service^^}_TOKEN=\"\$(cat $token_file)\""
    echo "   # or"
    echo "   source <($0 --export-env)"
}

list_tokens() {
    echo "📋 Saved Tokens:"
    echo ""

    if [ ! -d "$TOKEN_DIR" ] || [ -z "$(ls -A $TOKEN_DIR 2>/dev/null)" ]; then
        echo "   No tokens saved yet."
        echo ""
        echo "💡 Save a token:"
        echo "   $0 claude YOUR_TOKEN_HERE"
        return
    fi

    for token_file in "$TOKEN_DIR"/*.token; do
        [ -f "$token_file" ] || continue

        local service=$(basename "$token_file" .token)
        local token=$(cat "$token_file")
        local masked="${token:0:8}...${token: -8}"
        local size=$(stat -f%z "$token_file" 2>/dev/null || stat -c%s "$token_file")
        local modified=$(stat -f%Sm -t "%Y-%m-%d %H:%M" "$token_file" 2>/dev/null || stat -c%y "$token_file" | cut -d. -f1)

        echo "   ✓ $service"
        echo "     Token: $masked"
        echo "     Size: $size bytes"
        echo "     Modified: $modified"
        echo ""
    done

    echo "💡 Export to environment:"
    echo "   source <($0 --export-env)"
}

export_env() {
    for token_file in "$TOKEN_DIR"/*.token; do
        [ -f "$token_file" ] || continue

        local service=$(basename "$token_file" .token)
        local token=$(cat "$token_file")
        local var_name="${service^^}_TOKEN"
        var_name="${var_name//-/_}"

        echo "export ${var_name}=\"${token}\""
    done
}

# Main
case "${1:-}" in
    --help|-h)
        show_usage
        ;;
    --list|-l)
        list_tokens
        ;;
    --export-env)
        export_env
        ;;
    "")
        show_usage
        exit 1
        ;;
    *)
        if [ -z "$2" ]; then
            echo "❌ Error: Missing token argument"
            echo ""
            show_usage
            exit 1
        fi
        save_token "$1" "$2"
        ;;
esac
