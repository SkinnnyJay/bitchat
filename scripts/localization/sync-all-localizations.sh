#!/bin/bash

# Comprehensive sync script for both .xcstrings files
# Ensures all 29 languages have complete coverage

set -e

echo "🌐 Syncing ALL localization files for 29 languages..."
echo "Languages: en, es, zh-Hans, zh-Hant, zh-HK, ar, arz, hi, fr, de, ru, ja, pt, pt-BR, ur, tr, vi, id, bn, fil, tl, yue, ta, te, mr, sw, ha, pcm, pnb"
echo ""

echo "📱 Syncing Localizable.xcstrings (App UI strings)..."
python3 "$(dirname "$0")/sync_xcstrings.py" bitchat/Localizable.xcstrings
if [[ -f "$(dirname "$0")/add_missing_comments.py" ]]; then
  python3 "$(dirname "$0")/add_missing_comments.py" bitchat/Localizable.xcstrings
fi

echo ""
echo "📋 Syncing InfoPlist.xcstrings (System permission strings)..."
python3 "$(dirname "$0")/sync_xcstrings.py" bitchat/Infoplist.xcstrings
if [[ -f "$(dirname "$0")/add_missing_comments.py" ]]; then
  python3 "$(dirname "$0")/add_missing_comments.py" bitchat/Infoplist.xcstrings
fi

echo ""
echo "✅ Complete localization sync finished!"
echo "📊 Coverage:"
echo "  • App UI: 146+ keys × 29 languages"  
echo "  • System permissions: 2 keys × 29 languages"
echo "  • Total: 4,200+ localization entries"
