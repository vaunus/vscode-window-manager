#!/bin/bash
# Packages the VS Code extension as build/<name>-<version>.vsix and prints its path.
# A .vsix is a zip with a manifest, so this needs no npm tools.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

field() { plutil -extract "$1" raw -o - "$ROOT/package.json"; }
xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

NAME="$(field name)"
VERSION="$(field version)"
PUBLISHER="$(field publisher)"
DISPLAY_NAME="$(field displayName | xml)"
DESCRIPTION="$(field description | xml)"
ENGINE="$(field engines.vscode | xml)"

STAGE="$ROOT/build/vsix"
OUT="$ROOT/build/$NAME-$VERSION.vsix"
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/extension"
cp -R "$ROOT/package.json" "$ROOT/extension.js" "$ROOT/lib" "$STAGE/extension/"

cat > "$STAGE/extension.vsixmanifest" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="$NAME" Version="$VERSION" Publisher="$PUBLISHER" />
    <DisplayName>$DISPLAY_NAME</DisplayName>
    <Description xml:space="preserve">$DESCRIPTION</Description>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="$ENGINE" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui" />
      <Property Id="Microsoft.VisualStudio.Code.ExecutesCode" Value="true" />
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code" />
  </Installation>
  <Dependencies />
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
  </Assets>
</PackageManifest>
EOF

cat > "$STAGE/[Content_Types].xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension=".js" ContentType="application/javascript"/><Default Extension=".json" ContentType="application/json"/><Default Extension=".vsixmanifest" ContentType="text/xml"/></Types>
EOF

(cd "$STAGE" && zip -qrXD "$OUT" '[Content_Types].xml' extension.vsixmanifest extension)
rm -rf "$STAGE"
printf '%s\n' "$OUT"
