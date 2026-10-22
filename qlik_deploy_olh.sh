#!/usr/bin/env bash
################################################################
#  qlik_deploy_olh.sh  –  Full Edition  (AWS + Google Cloud)
#
#  Provisions the cloud resources Qlik Open Lakehouse needs, then hands off to
#  the matching Terraform root module in terraform/<cloud>/.
#
#  Cloud support:
#    • AWS          GA
#    • Google Cloud Private Preview (opened 2 Sep 2026; GA planned Q4 2026).
#                   Preview scope is CDC and SaaS sources only - streaming
#                   (Kafka/GCS) and Qlik Replicate sources arrive later, which
#                   is why the GCP path provisions no stream resource.
#
#  Features:
#    • Pre-flight IAM permission checker
#    • Duplicate resource guard
#    • Dry-run mode  (--dry-run flag)
#    • Teardown mode (--teardown flag)
#    • Drift detection (--drift flag)
#    • Auto-discover + create-on-missing for all resource groups
#    • Tagging compliance with required tags
#    • HTML deployment report
#    • Auto-open qlik-network-integration.txt after deploy
#
#  Usage:
#    ./qlik_deploy_olh.sh                      # normal deploy (asks for cloud)
#    ./qlik_deploy_olh.sh --gcp                # skip the cloud prompt
#    ./qlik_deploy_olh.sh --cloud=aws          # same, long form
#    ./qlik_deploy_olh.sh --dry-run            # simulate only
#    ./qlik_deploy_olh.sh --drift              # drift check only
#    ./qlik_deploy_olh.sh --teardown           # destroy resources
################################################################

set -euo pipefail

#region ── Colours & Icons ──────────────────────────────────────
CYN='\033[0;36m'; GRN='\033[0;32m'; YLW='\033[0;33m'
RED='\033[0;31m'; WHT='\033[1;37m'; GRY='\033[0;37m'
BLU='\033[0;34m'; MAG='\033[0;35m'; RST='\033[0m'
OK="✔"; WRN="⚠"; ERR="✖"; ARW="→"; SEP="$(printf '─%.0s' {1..60})"
#endregion

#region ── Flags ────────────────────────────────────────────────
DRY_RUN=false; TEARDOWN=false; DRIFT_ONLY=false
CLOUD=""
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=true    ;;
    --teardown)   TEARDOWN=true   ;;
    --drift)      DRIFT_ONLY=true ;;
    --aws)        CLOUD="aws"     ;;
    --gcp|--gcloud|--google) CLOUD="gcp" ;;
    --cloud=*)    CLOUD="${arg#*=}" ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^#//'
      exit 0 ;;
  esac
done

case "$CLOUD" in
  ""|aws|gcp) ;;
  *) echo "Unknown --cloud value '$CLOUD' (expected aws or gcp)." >&2; exit 1 ;;
esac
#endregion

#region ── Target Cloud ─────────────────────────────────────────
# Asked before the tool check so we only demand the CLI we are going to use.
if [[ -z "$CLOUD" ]]; then
  echo ""
  echo -e "  ${WHT}Which cloud is this lakehouse going into?${RST}"
  echo ""
  echo -e "    [1] ${CYN}Amazon Web Services${RST}   ${GRY}- generally available${RST}"
  echo -e "    [2] ${CYN}Google Cloud${RST}          ${YLW}- Private Preview${RST} ${GRY}(CDC + SaaS sources only)${RST}"
  echo ""
  while true; do
    read -rp "    Select (1-2) [default: 1]: " _cloud_sel
    _cloud_sel="${_cloud_sel:-1}"
    case "$_cloud_sel" in
      1) CLOUD="aws"; break ;;
      2) CLOUD="gcp"; break ;;
      *) echo -e "    ${RED}${ERR}  Enter 1 or 2.${RST}" ;;
    esac
  done
fi

if [[ "$CLOUD" == "gcp" ]]; then
  CLOUD_LABEL="Google Cloud"
  CLOUD_CLI="gcloud"
  TF_DIR="terraform/gcp"
  if $DRIFT_ONLY || $TEARDOWN; then
    echo ""
    echo "  --drift and --teardown are implemented for AWS only. Remove the flag,"
    echo "  or manage the Google Cloud resources with 'terraform -chdir=terraform/gcp destroy'." >&2
    exit 1
  fi
  echo ""
  echo -e "  ${YLW}${WRN}  Qlik Open Lakehouse on Google Cloud is in Private Preview (opened 2 Sep 2026).${RST}"
  echo -e "  ${GRY}      Preview scope: CDC and SaaS sources. Streaming (Kafka/GCS) and Qlik${RST}"
  echo -e "  ${GRY}      Replicate sources arrive later in the preview. Your tenant must be${RST}"
  echo -e "  ${GRY}      enrolled before a lakehouse cluster can be created.${RST}"
else
  CLOUD_LABEL="AWS"
  CLOUD_CLI="aws"
  TF_DIR="terraform/aws"
fi

# Resolve paths from the script's own location. An elevated or relocated shell
# has a different working directory, and outputs used to land somewhere the
# user could not find. Resolved here rather than at the output-files step so
# --drift and --teardown, which run long before that point, see the same
# terraform/<cloud>/terraform.tfvars.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TF_PATH="${SCRIPT_DIR}/${TF_DIR}"
TFVARS="${TF_PATH}/terraform.tfvars"
#endregion

#region ── Tool Check & Auto-Install ────────────────────────────

TERRAFORM_OK=false
AWS_OK=false
GCLOUD_OK=false
PYTHON_OK=false

# ── Inline yes/no prompt (the full confirm() is defined later) ──
_yn_prompt() {
  local msg="$1" ans
  read -rp "  ${msg} [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ── Find a working Python 3 interpreter ───────────────────────
# On Windows Git Bash, `python3` is often a Microsoft Store stub that
# prints an install prompt and exits non-zero. Probe candidates and
# pick the first that actually runs and reports Python 3.
PY=""
for candidate in python3 python py; do
  if command -v "$candidate" &>/dev/null \
     && "$candidate" -c "import sys; sys.exit(0 if sys.version_info[0]==3 else 1)" 2>/dev/null; then
    PY="$candidate"
    break
  fi
done
# Single-arg helper: `py "import x; print(x.foo)"`
py() { [[ -n "$PY" ]] && "$PY" -c "$1" 2>/dev/null || true; }

# ── Detect OS package manager ─────────────────────────────────
detect_pkg_manager() {
  if   command -v apt-get &>/dev/null; then echo "apt"
  elif command -v yum     &>/dev/null; then echo "yum"
  elif command -v dnf     &>/dev/null; then echo "dnf"
  elif command -v brew    &>/dev/null; then echo "brew"
  else                                      echo "none"
  fi
}
PKG_MGR=$(detect_pkg_manager)

# ── Install menu for a missing tool ──────────────────────────
install_tool() {
  local tool="$1"
  echo ""
  echo -e "  ${YLW}${WRN}  '$tool' was not found on this system.${RST}"
  echo ""

  # Build option list
  local opts=("download")                        # always first / preferred
  [[ "$PKG_MGR" != "none" ]] && opts+=("$PKG_MGR")
  opts+=("manual" "skip")

  echo -e "  ${WHT}How would you like to install ${tool}?${RST}"
  for i in "${!opts[@]}"; do
    local n=$(( i + 1 ))
    case "${opts[$i]}" in
      download)
        if [[ "$tool" == "terraform" ]]; then
          echo -e "  [${n}] ${GRN}Download latest Terraform zip from HashiCorp  (recommended)${RST}"
        elif [[ "$tool" == "aws" ]]; then
          echo -e "  [${n}] ${GRN}Download AWS CLI v2 installer  (recommended)${RST}"
        elif [[ "$tool" == "gcloud" ]]; then
          echo -e "  [${n}] ${GRN}Download the Google Cloud CLI archive  (recommended)${RST}"
        else
          echo -e "  [${n}] ${GRN}Download and install ${tool}  (recommended)${RST}"
        fi ;;
      apt|yum|dnf|brew)
        echo -e "  [${n}] ${CYN}Install via ${opts[$i]}${RST}" ;;
      manual)
        echo -e "  [${n}] ${GRY}Show manual install instructions${RST}" ;;
      skip)
        echo -e "  [${n}] ${GRY}Skip and continue without ${tool}${RST}" ;;
    esac
  done
  echo ""

  local sel
  while true; do
    read -rp "    Select (1-${#opts[@]}): " sel
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#opts[@]} )) && break
    echo -e "    ${RED}${ERR}  Enter a number 1-${#opts[@]}.${RST}"
  done
  local choice="${opts[$((sel-1))]}"

  case "$choice" in

    # ── Preferred: direct download ──────────────────────────
    download)
      if [[ "$tool" == "terraform" ]]; then
        echo ""
        echo -e "    ${GRY}${ARW} Fetching latest Terraform version ...${RST}"
        local tf_ver
        # Try official HashiCorp releases API first (most reliable), fall back to checkpoint API
        tf_ver=$(curl -fsSL "https://api.releases.hashicorp.com/v1/releases/terraform/latest" 2>/dev/null \
          | "$PY" -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null)
        if [[ -z "$tf_ver" ]]; then
          tf_ver=$(curl -fsSL "https://checkpoint-api.hashicorp.com/v1/check/terraform" 2>/dev/null \
            | "$PY" -c "import sys,json; print(json.load(sys.stdin)['current_version'])" 2>/dev/null)
        fi
        # Fallback to a known-recent version if both APIs fail
        [[ -z "$tf_ver" ]] && tf_ver="1.15.1"
        echo -e "    ${GRY}Latest version: ${tf_ver}${RST}"

        # Pick arch (amd64 / arm64) and OS
        local arch; arch=$(uname -m)
        case "$arch" in
          x86_64|amd64) arch="amd64" ;;
          aarch64|arm64) arch="arm64" ;;
          *)            arch="amd64" ;;  # default; HashiCorp publishes amd64 + arm64
        esac
        local os="linux"
        [[ "$(uname)" == "Darwin" ]] && os="darwin"
        local tf_url="https://releases.hashicorp.com/terraform/${tf_ver}/terraform_${tf_ver}_${os}_${arch}.zip"

        local tf_zip="/tmp/terraform_${tf_ver}.zip"
        local tf_dest="/usr/local/bin"

        echo -e "    ${GRY}${ARW} Downloading: ${tf_url}${RST}"
        if ! curl -fSL "$tf_url" -o "$tf_zip"; then
          echo -e "    ${RED}${ERR}  Download failed (network / proxy issue?).${RST}"
          rm -f "$tf_zip"; return 1
        fi
        if [[ ! -s "$tf_zip" ]]; then
          echo -e "    ${RED}${ERR}  Downloaded zip is empty.${RST}"; rm -f "$tf_zip"; return 1
        fi

        # Try writing without sudo first; fall back to sudo if dir not writable
        local sudo_cmd=""
        [[ ! -w "$tf_dest" ]] && sudo_cmd="sudo"
        [[ -n "$sudo_cmd" ]] && echo -e "    ${GRY}${ARW} ${tf_dest} requires sudo for write.${RST}"

        echo -e "    ${GRY}${ARW} Extracting to ${tf_dest} ...${RST}"
        if command -v unzip &>/dev/null; then
          if ! $sudo_cmd unzip -o "$tf_zip" terraform -d "$tf_dest"; then
            echo -e "    ${RED}${ERR}  Extraction failed.${RST}"; rm -f "$tf_zip"; return 1
          fi
        else
          # Python fallback when unzip isn't available
          local extract_script="/tmp/tf_extract_$$.py"
          cat > "$extract_script" <<PYEOF
import zipfile, os, sys
with zipfile.ZipFile('${tf_zip}') as z:
    z.extract('terraform', '${tf_dest}')
PYEOF
          if ! $sudo_cmd "$PY" "$extract_script"; then
            echo -e "    ${RED}${ERR}  Python extraction failed.${RST}"
            rm -f "$tf_zip" "$extract_script"; return 1
          fi
          rm -f "$extract_script"
        fi
        $sudo_cmd chmod +x "${tf_dest}/terraform"
        rm -f "$tf_zip"

        # Force PATH refresh in case /usr/local/bin wasn't already on it
        case ":$PATH:" in
          *":${tf_dest}:"*) ;;
          *) export PATH="${tf_dest}:$PATH" ;;
        esac

        if command -v terraform &>/dev/null; then
          local ver; ver=$(terraform version -json 2>/dev/null | "$PY" -c "import sys,json; print(json.load(sys.stdin)['terraform_version'])" 2>/dev/null || echo "$tf_ver")
          echo -e "    ${GRN}${OK}  Terraform v${ver} installed.${RST}"
          return 0
        else
          echo -e "    ${YLW}${WRN}  Extracted to ${tf_dest} but 'terraform' not on PATH. Re-open your shell.${RST}"
          return 1
        fi

      elif [[ "$tool" == "aws" ]]; then
        echo ""
        local aws_zip="/tmp/awscli_v2.zip"
        local aws_dir="/tmp/aws"
        echo -e "    ${GRY}${ARW} Downloading AWS CLI v2 ...${RST}"

        # Snapshot pre-install version so we can detect upgrade vs first-install
        local pre_ver=""
        command -v aws &>/dev/null && pre_ver=$(aws --version 2>&1 | grep -oE 'aws-cli/[0-9.]+' | cut -d/ -f2)

        if [[ "$(uname)" == "Darwin" ]]; then
          local pkg="/tmp/AWSCLIV2.pkg"
          if ! curl -fSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "$pkg"; then
            echo -e "    ${RED}${ERR}  Download failed (network / proxy issue?).${RST}"
            rm -f "$pkg"; return 1
          fi
          if [[ ! -s "$pkg" ]]; then
            echo -e "    ${RED}${ERR}  Downloaded pkg is empty.${RST}"; rm -f "$pkg"; return 1
          fi
          echo -e "    ${GRY}${ARW} Running installer (needs sudo)...${RST}"
          if ! sudo installer -pkg "$pkg" -target /; then
            echo -e "    ${RED}${ERR}  Installer failed. Try installing manually from the same URL.${RST}"
            rm -f "$pkg"; return 1
          fi
          rm -f "$pkg"
        else
          if ! curl -fSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$aws_zip"; then
            echo -e "    ${RED}${ERR}  Download failed (network / proxy issue?).${RST}"
            rm -f "$aws_zip"; return 1
          fi
          if [[ ! -s "$aws_zip" ]]; then
            echo -e "    ${RED}${ERR}  Downloaded zip is empty.${RST}"; rm -f "$aws_zip"; return 1
          fi
          if ! unzip -q -o "$aws_zip" -d "$aws_dir"; then
            echo -e "    ${RED}${ERR}  Failed to extract installer zip.${RST}"
            rm -rf "$aws_zip" "$aws_dir"; return 1
          fi
          echo -e "    ${GRY}${ARW} Running installer (needs sudo)...${RST}"
          # --update is safe for first-install too
          if ! sudo "${aws_dir}/aws/install" --update; then
            echo -e "    ${RED}${ERR}  Installer failed. See output above.${RST}"
            rm -rf "$aws_zip" "$aws_dir"; return 1
          fi
          rm -rf "$aws_zip" "$aws_dir"
        fi

        if command -v aws &>/dev/null; then
          local post_ver; post_ver=$(aws --version 2>&1 | grep -oE 'aws-cli/[0-9.]+' | cut -d/ -f2)
          if [[ -n "$pre_ver" && "$pre_ver" == "$post_ver" ]]; then
            echo -e "    ${YLW}${WRN}  Install ran but version unchanged (still v${post_ver}). Open a fresh shell and re-check.${RST}"
            return 1
          fi
          echo -e "    ${GRN}${OK}  AWS CLI v${post_ver} installed.${RST}"
          return 0
        else
          echo -e "    ${YLW}${WRN}  Installed but 'aws' not on PATH. Re-open your shell and re-run.${RST}"
          return 1
        fi

      elif [[ "$tool" == "gcloud" ]]; then
        # Google publishes a versioned archive per OS/arch plus an install.sh
        # that wires up PATH. We extract under $HOME so no sudo is needed.
        local g_os="linux" g_arch
        [[ "$(uname)" == "Darwin" ]] && g_os="darwin"
        case "$(uname -m)" in
          x86_64|amd64)  g_arch="x86_64" ;;
          aarch64|arm64) g_arch="arm" ;;
          *)             g_arch="x86_64" ;;
        esac
        [[ "$g_os" == "darwin" && "$g_arch" == "arm" ]] && g_arch="arm"

        local g_url="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-${g_os}-${g_arch}.tar.gz"
        local g_tgz="/tmp/google-cloud-cli.tar.gz"
        local g_dest="$HOME"

        echo -e "    ${GRY}${ARW} Downloading: ${g_url}${RST}"
        if ! curl -fSL "$g_url" -o "$g_tgz"; then
          echo -e "    ${RED}${ERR}  Download failed (network / proxy issue?).${RST}"
          rm -f "$g_tgz"; return 1
        fi
        if [[ ! -s "$g_tgz" ]]; then
          echo -e "    ${RED}${ERR}  Downloaded archive is empty.${RST}"; rm -f "$g_tgz"; return 1
        fi

        echo -e "    ${GRY}${ARW} Extracting to ${g_dest}/google-cloud-sdk ...${RST}"
        if ! tar -xzf "$g_tgz" -C "$g_dest"; then
          echo -e "    ${RED}${ERR}  Extraction failed.${RST}"; rm -f "$g_tgz"; return 1
        fi
        rm -f "$g_tgz"

        echo -e "    ${GRY}${ARW} Running install.sh (non-interactive) ...${RST}"
        "${g_dest}/google-cloud-sdk/install.sh" --quiet --usage-reporting=false           --command-completion=true --path-update=true >/dev/null 2>&1 || true

        # install.sh edits the shell rc file, which does not help this already
        # running shell - put it on PATH directly.
        case ":$PATH:" in
          *":${g_dest}/google-cloud-sdk/bin:"*) ;;
          *) export PATH="${g_dest}/google-cloud-sdk/bin:$PATH" ;;
        esac

        if command -v gcloud &>/dev/null; then
          local g_ver; g_ver=$(gcloud version 2>/dev/null | head -1)
          echo -e "    ${GRN}${OK}  ${g_ver} installed.${RST}"
          return 0
        else
          echo -e "    ${YLW}${WRN}  Installed but 'gcloud' not on PATH. Re-open your shell and re-run.${RST}"
          return 1
        fi

      elif [[ "$tool" == "python3" ]]; then
        echo -e "    ${YLW}  python3 download not automated -- use your system package manager.${RST}"
        return 1
      fi ;;

    # ── Package manager installs ────────────────────────────
    apt)
      case "$tool" in
        terraform)
          echo -e "    ${GRY}${ARW} Adding HashiCorp apt repo and installing terraform ...${RST}"
          sudo apt-get update -qq
          sudo apt-get install -y gnupg software-properties-common curl &>/dev/null
          curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
          echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
            | sudo tee /etc/apt/sources.list.d/hashicorp.list &>/dev/null
          sudo apt-get update -qq && sudo apt-get install -y terraform &>/dev/null ;;
        aws)
          echo -e "    ${YLW}${WRN}  The 'awscli' apt package is AWS CLI v1 (deprecated).${RST}"
          echo -e "    ${YLW}      v1 is missing many features needed by this wizard (SSO, IMDSv2 helpers, etc.).${RST}"
          echo -e "    ${WHT}      Strongly recommended: choose 'download' instead -- it installs AWS CLI v2.${RST}"
          if ! _yn_prompt "  Install v1 anyway via apt?"; then
            echo -e "    ${GRY}      Skipping apt install. Re-run and pick 'download'.${RST}"
            return 1
          fi
          sudo apt-get update -qq && sudo apt-get install -y awscli &>/dev/null ;;
        python3)
          sudo apt-get update -qq && sudo apt-get install -y python3 &>/dev/null ;;
      esac ;;

    yum|dnf)
      case "$tool" in
        terraform)
          sudo "$PKG_MGR" install -y yum-utils &>/dev/null
          sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo &>/dev/null
          sudo "$PKG_MGR" install -y terraform &>/dev/null ;;
        aws)
          echo -e "    ${YLW}${WRN}  The 'awscli' ${PKG_MGR} package is AWS CLI v1 (deprecated).${RST}"
          echo -e "    ${WHT}      Strongly recommended: choose 'download' instead -- it installs AWS CLI v2.${RST}"
          if ! _yn_prompt "  Install v1 anyway via ${PKG_MGR}?"; then
            echo -e "    ${GRY}      Skipping. Re-run and pick 'download'.${RST}"
            return 1
          fi
          sudo "$PKG_MGR" install -y awscli &>/dev/null ;;
        python3)
          sudo "$PKG_MGR" install -y python3 &>/dev/null ;;
      esac ;;

    brew)
      case "$tool" in
        terraform) brew tap hashicorp/tap && brew install hashicorp/tap/terraform ;;
        aws)       brew install awscli ;;
        gcloud)    brew install --cask google-cloud-sdk ;;
        python3)   brew install python3 ;;
      esac ;;

    # ── Manual instructions ─────────────────────────────────
    manual)
      echo ""
      case "$tool" in
        terraform)
          echo -e "  ${WHT}Terraform Manual Install:${RST}"
          echo -e "  ${GRY}  1. Visit: https://developer.hashicorp.com/terraform/downloads${RST}"
          echo -e "  ${GRY}  2. Download the Linux/macOS AMD64 zip${RST}"
          echo -e "  ${GRY}  3. unzip terraform_*.zip -d /usr/local/bin/${RST}"
          echo -e "  ${GRY}  4. chmod +x /usr/local/bin/terraform${RST}"
          echo -e "  ${GRY}  5. terraform --version${RST}" ;;
        aws)
          echo -e "  ${WHT}AWS CLI Manual Install (Linux):${RST}"
          echo -e "  ${GRY}  curl https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip${RST}"
          echo -e "  ${GRY}  unzip awscliv2.zip && sudo ./aws/install${RST}"
          echo -e "  ${GRY}  aws --version${RST}" ;;
        gcloud)
          echo -e "  ${WHT}Google Cloud CLI Manual Install:${RST}"
          echo -e "  ${GRY}  Linux/macOS : curl https://sdk.cloud.google.com | bash${RST}"
          echo -e "  ${GRY}  macOS (brew): brew install --cask google-cloud-sdk${RST}"
          echo -e "  ${GRY}  Docs        : https://cloud.google.com/sdk/docs/install${RST}"
          echo -e "  ${GRY}  gcloud version${RST}" ;;
        python3)
          echo -e "  ${WHT}Python3 Manual Install:${RST}"
          echo -e "  ${GRY}  Ubuntu/Debian : sudo apt-get install python3${RST}"
          echo -e "  ${GRY}  RHEL/Amazon   : sudo yum install python3${RST}"
          echo -e "  ${GRY}  macOS         : brew install python3${RST}" ;;
      esac
      echo ""
      echo -e "  ${YLW}Re-run this script after installing.${RST}"
      exit 0 ;;

    # ── Skip ────────────────────────────────────────────────
    skip)
      echo -e "    ${YLW}${WRN}  Skipping ${tool} -- some steps will be unavailable.${RST}"
      return 1 ;;
  esac

  # Verify install succeeded after pkg manager step
  if command -v "$tool" &>/dev/null; then
    echo -e "    ${GRN}${OK}  ${tool} installed successfully.${RST}"
    return 0
  else
    echo -e "    ${YLW}${WRN}  ${tool} still not found. You may need to re-open your shell.${RST}"
    return 1
  fi
}

# ── Run checklist ─────────────────────────────────────────────
echo ""
echo -e "  ${WHT}Checking required tools ...${RST}"
echo ""
printf "  ${CYN}%-20s %-10s %-38s %s${RST}\n" "Tool" "Required" "Version / Status" "Action"
echo "  $(printf '%0.s─' {1..75})"

check_tool() {
  local name="$1" label="$2" req="$3" ver_cmd="$4"
  if command -v "$name" &>/dev/null; then
    local ver
    ver=$(eval "$ver_cmd" 2>/dev/null || echo "found")
    printf "  %-20s %-10s %-38s " "$label" "$req" "$ver"
    echo -e "${GRN}${OK}  Ready${RST}"
    return 0
  else
    printf "  %-20s %-10s %-38s " "$label" "$req" "NOT FOUND"
    echo -e "${YLW}${WRN}  Missing${RST}"
    return 1
  fi
}

# ── Compare installed vs latest version (semver) ──────────────
# Returns 0 if installed is up-to-date, 1 if outdated, 2 if cannot determine
fetch_latest_terraform_version() {
  local v
  v=$(curl -fsSL "https://api.releases.hashicorp.com/v1/releases/terraform/latest" 2>/dev/null \
    | "$PY" -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null)
  [[ -z "$v" ]] && v=$(curl -fsSL "https://checkpoint-api.hashicorp.com/v1/check/terraform" 2>/dev/null \
    | "$PY" -c "import sys,json; print(json.load(sys.stdin)['current_version'])" 2>/dev/null)
  echo "$v"
}

semver_lt() {
  # Returns 0 (true) if $1 < $2
  [[ -z "$PY" ]] && return 2
  "$PY" -c "
import sys
def parse(v): return tuple(int(x) for x in v.strip().lstrip('v').split('.') if x.isdigit())
sys.exit(0 if parse('$1') < parse('$2') else 1)
" 2>/dev/null
}

if [[ "$CLOUD" == "gcp" ]]; then
  check_tool "gcloud"  "gcloud CLI" "YES"     "gcloud version 2>/dev/null | head -1" && GCLOUD_OK=true
else
  check_tool "aws"     "AWS CLI"   "YES"      "aws --version 2>&1 | head -1"  && AWS_OK=true
fi
check_tool "terraform" "Terraform" "optional" "terraform version 2>/dev/null | head -1" && TERRAFORM_OK=true

# Python check uses the detected PY (not the literal `python3` which on
# Windows resolves to the Microsoft Store stub)
if [[ -n "$PY" ]]; then
  printf "  %-20s %-10s %-38s " "Python 3" "YES" "$("$PY" --version 2>&1)"
  echo -e "${GRN}${OK}  Ready  (${PY})${RST}"
  PYTHON_OK=true
else
  printf "  %-20s %-10s %-38s " "Python 3" "YES" "NOT FOUND"
  echo -e "${YLW}${WRN}  Missing${RST}"
fi

echo "  $(printf '%0.s─' {1..75})"

# ── Offer install for each missing tool ───────────────────────
# Use the *_OK flags as the source of truth (not just `command -v ...`),
# because on Windows Git Bash `command -v python3` returns 0 for the
# Microsoft Store stub even though the stub doesn't actually run Python.
if [[ "$CLOUD" == "gcp" ]]; then
  _tool_items=("gcloud:GCLOUD_OK" "terraform:TERRAFORM_OK" "python3:PYTHON_OK")
else
  _tool_items=("aws:AWS_OK" "terraform:TERRAFORM_OK" "python3:PYTHON_OK")
fi
for item in "${_tool_items[@]}"; do
  local_tool="${item%%:*}"
  local_var="${item##*:}"
  if [[ "$(eval echo \$$local_var)" != "true" ]]; then
    if install_tool "$local_tool"; then
      eval "$local_var=true"
    fi
  fi
done

# ── Re-detect Python if it was just installed ─────────────────
# $PY was probed at script start; a mid-run install leaves it empty, which
# would silently break every JSON-parsing helper for the rest of the run.
if [[ -z "$PY" && "$PYTHON_OK" == "true" ]]; then
  for candidate in python3 python py; do
    if command -v "$candidate" &>/dev/null \
       && "$candidate" -c "import sys; sys.exit(0 if sys.version_info[0]==3 else 1)" 2>/dev/null; then
      PY="$candidate"
      echo -e "  ${GRN}${OK}  Python detected after install: ${PY}${RST}"
      break
    fi
  done
  if [[ -z "$PY" ]]; then
    PYTHON_OK=false
    echo -e "  ${YLW}${WRN}  Python installed but not usable in this shell yet -- re-open your shell and re-run.${RST}"
  fi
fi

# ── If Terraform is installed, check if it's outdated ────────
if [[ "$TERRAFORM_OK" == "true" ]]; then
  installed_tf=$(terraform version -json 2>/dev/null | "$PY" -c "import sys,json; print(json.load(sys.stdin).get('terraform_version',''))" 2>/dev/null || echo "")
  latest_tf=$(fetch_latest_terraform_version)
  if [[ -n "$installed_tf" && -n "$latest_tf" ]] && semver_lt "$installed_tf" "$latest_tf"; then
    echo ""
    echo -e "  ${YLW}${WRN}  Terraform v${installed_tf} is installed -- latest is v${latest_tf}.${RST}"
    if _yn_prompt "Upgrade Terraform to v${latest_tf}?"; then
      install_tool "terraform"
    fi
  elif [[ -n "$installed_tf" && -n "$latest_tf" ]]; then
    echo -e "  ${GRN}${OK}  Terraform v${installed_tf} is up to date.${RST}"
  fi
fi

# ── Fetch latest AWS CLI v2 version from GitHub tags API ─────
fetch_latest_aws_cli_version() {
  curl -fsSL "https://api.github.com/repos/aws/aws-cli/tags?per_page=1" 2>/dev/null \
    | "$PY" -c "import sys,json; tags=json.load(sys.stdin); print(tags[0]['name'] if tags else '')" 2>/dev/null
}

# ── If AWS CLI is installed, check if it's outdated ──────────
if [[ "$AWS_OK" == "true" ]]; then
  installed_aws=$(aws --version 2>&1 | grep -oE 'aws-cli/[0-9.]+' | cut -d/ -f2)
  latest_aws=$(fetch_latest_aws_cli_version)
  if [[ -n "$installed_aws" && -n "$latest_aws" ]] && semver_lt "$installed_aws" "$latest_aws"; then
    echo ""
    echo -e "  ${YLW}${WRN}  AWS CLI v${installed_aws} is installed -- latest is v${latest_aws}.${RST}"
    if _yn_prompt "Upgrade AWS CLI to v${latest_aws}?"; then
      install_tool "aws"
    fi
  elif [[ -n "$installed_aws" && -n "$latest_aws" ]]; then
    echo -e "  ${GRN}${OK}  AWS CLI v${installed_aws} is up to date.${RST}"
  elif [[ -n "$installed_aws" ]]; then
    # Couldn't reach GitHub - fall back to manual offer
    echo -e "  ${GRY}  AWS CLI v${installed_aws} detected (latest-version lookup unavailable).${RST}"
    if _yn_prompt "Pull latest AWS CLI v2 now?"; then
      install_tool "aws"
    fi
  fi
fi

# ── If gcloud is installed, offer a component update ─────────
# gcloud carries its own updater, so there is no GitHub tag to compare against
# the way there is for the AWS CLI - ask it whether it considers itself stale.
if [[ "$GCLOUD_OK" == "true" ]]; then
  installed_gcloud=$(gcloud version --format="value('Google Cloud SDK')" 2>/dev/null | head -1)
  [[ -z "$installed_gcloud" ]] && installed_gcloud=$(gcloud version 2>/dev/null | head -1 | grep -oE '[0-9]+[.][0-9]+[.][0-9]+')
  if gcloud components list --format="value(state.name)" 2>/dev/null | grep -qi "update available"; then
    echo ""
    echo -e "  ${YLW}${WRN}  gcloud ${installed_gcloud} has component updates available.${RST}"
    if _yn_prompt "Run 'gcloud components update' now?"; then
      gcloud components update --quiet ||         echo -e "  ${YLW}${WRN}  Update failed (a package-manager install of gcloud updates via the package manager).${RST}"
    fi
  elif [[ -n "$installed_gcloud" ]]; then
    echo -e "  ${GRN}${OK}  gcloud ${installed_gcloud} is up to date.${RST}"
  fi
fi

# ── Summary ───────────────────────────────────────────────────
echo ""
echo -e "  ${WHT}Tool Check Summary:${RST}"
echo ""
if [[ "$CLOUD" == "gcp" ]]; then
  _summary_items=("gcloud CLI:gcloud:$GCLOUD_OK:required" "Terraform:terraform:$TERRAFORM_OK:optional" "Python3:python3:$PYTHON_OK:required")
else
  _summary_items=("AWS CLI:aws:$AWS_OK:required" "Terraform:terraform:$TERRAFORM_OK:optional" "Python3:python3:$PYTHON_OK:required")
fi
for item in "${_summary_items[@]}"; do
  IFS=':' read -r lbl nm ok req <<< "$item"
  if [[ "$ok" == "true" ]]; then
    printf "  %-20s " "$lbl"; echo -e "${GRN}${OK}  Ready${RST}"
  elif [[ "$req" == "required" ]]; then
    printf "  %-20s " "$lbl"; echo -e "${RED}${ERR}  Missing (required)${RST}"
  else
    printf "  %-20s " "$lbl"; echo -e "${YLW}${WRN}  Missing -- deploy steps will be skipped${RST}"
  fi
done
echo ""

# ── Abort if required tools still missing ────────────────────
if [[ "$CLOUD" == "gcp" ]]; then
  if [[ "$GCLOUD_OK" != "true" ]]; then
    echo -e "  ${RED}${ERR}  The Google Cloud CLI is required. Please install it and re-run.${RST}"; exit 1
  fi
elif [[ "$AWS_OK" != "true" ]]; then
  echo -e "  ${RED}${ERR}  AWS CLI is required. Please install it and re-run.${RST}"; exit 1
fi
if [[ "$PYTHON_OK" != "true" ]]; then
  echo -e "  ${RED}${ERR}  Python3 is required. Please install it and re-run.${RST}"; exit 1
fi
if [[ "$TERRAFORM_OK" != "true" ]]; then
  echo -e "  ${YLW}${WRN}  Terraform not available -- init/plan/apply steps will be skipped.${RST}"
  echo -e "  ${GRY}      Discovery, file generation and tagging will still run.${RST}"
  echo ""
  _yn_prompt "  Continue without Terraform?" || { echo -e "${RED}  Aborted.${RST}"; exit 0; }
fi

#endregion

#region ── Helpers ──────────────────────────────────────────────

header() {
  echo ""; echo -e "${CYN}$(printf '═%.0s' {1..60})${RST}"
  echo -e "${CYN}  $1${RST}"
  echo -e "${CYN}$(printf '═%.0s' {1..60})${RST}"; echo ""
}
section() { echo -e "\n  ${MAG}── $1 ──${RST}\n"; }

# prompt_val <label> <default> <regex> <errmsg>  → REPLY
prompt_val() {
  local lbl="$1" def="$2" rgx="$3" err="$4"
  while true; do
    local d="$lbl"; [[ -n "$def" ]] && d="$lbl [default: $def]"
    read -rp "    $d: " val; val="${val:-$def}"
    if [[ -n "$rgx" ]] && ! [[ "$val" =~ $rgx ]]; then
      echo -e "    ${RED}${ERR}  $err${RST}"
    else REPLY="$val"; return; fi
  done
}

prompt_choice() {
  local lbl="$1"; shift; local opts=()
  while [[ "$1" != "--" ]]; do opts+=("$1"); shift; done; shift
  local def="$1" lst; lst=$(IFS=" | "; echo "${opts[*]}")
  while true; do
    prompt_val "$lbl ($lst)" "$def" "" ""
    for o in "${opts[@]}"; do [[ "$REPLY" == "$o" ]] && return; done
    echo -e "    ${RED}${ERR}  Must be: $lst${RST}"
  done
}

confirm() { prompt_choice "$1" "y" "n" -- "y"; [[ "$REPLY" == "y" ]]; }

abort_on_fail() { [[ "$1" -ne 0 ]] && { echo -e "\n${RED}${ERR}  $2${RST}\n"; exit 1; }; }

# dry_exec: prints command in dry-run; runs it in live mode
dry_exec() {
  if $DRY_RUN; then
    echo -e "  ${YLW}[DRY-RUN] Would run: $*${RST}"
  else
    eval "$@"
  fi
}

pick_resource() {
  # pick_resource <title> <newline-ids> <newline-labels>  → REPLY
  local title="$1" IFS_B=$IFS
  IFS=$'\n' read -rd '' -a ids    <<< "$2" || true
  IFS=$'\n' read -rd '' -a labels <<< "$3" || true
  IFS=$IFS_B
  [[ ${#ids[@]} -eq 0 ]] && { REPLY=""; return; }
  echo -e "    ${YLW}Found existing ${title}:${RST}"
  for i in "${!ids[@]}"; do
    echo -e "    [$(( i+1 ))] ${WHT}${labels[$i]}${RST}"
  done
  echo -e "    [N] ${GRY}Create a new one instead${RST}\n"
  while true; do
    read -rp "    Select (1-${#ids[@]} or N): " sel; sel="${sel^^}"
    [[ "$sel" == "N" ]] && { REPLY=""; return; }
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=${#ids[@]} )); then
      REPLY="${ids[$((sel-1))]}"; return; fi
    echo -e "    ${RED}${ERR}  Enter 1–${#ids[@]} or N.${RST}"
  done
}

tag_spec() {
  # tag_spec <resource-type> <name> <owner> <env> <create-date>
  echo "ResourceType=$1,Tags=[\
{Key=Name,Value=$2},\
{Key=Owner,Value=$3},\
{Key=Environment,Value=$4},\
{Key=Workload,Value=qlik-olh},\
{Key=Application,Value=open-lakehouse},\
{Key=CreateDate,Value=$5},\
{Key=ManagedBy,Value=script}]"
}

# (py() is defined at the top of the script with the detected PY interpreter)

#endregion

#region ── Banner ───────────────────────────────────────────────
clear
MODE_LABEL="LIVE"
$DRY_RUN    && MODE_LABEL="${YLW}DRY-RUN${RST}"
$TEARDOWN   && MODE_LABEL="${RED}TEARDOWN${RST}"
$DRIFT_ONLY && MODE_LABEL="${MAG}DRIFT DETECTION${RST}"

header "Qlik Open Lakehouse  –  ${CLOUD_LABEL} Auto-Discovery  [${MODE_LABEL}]"
$DRY_RUN  && echo -e "  ${YLW}${WRN}  DRY-RUN MODE: No ${CLOUD_LABEL} resources will be created or modified.${RST}"
$TEARDOWN && echo -e "  ${RED}${WRN}  TEARDOWN MODE: Resources will be permanently deleted.${RST}"
echo ""
#endregion

################################################################
#  GROUP 1 – Identity & Naming
################################################################
header "Group 1 of 5  –  Identity & Naming"

prompt_val "Owner initials (2–6 lowercase, e.g. rgs)" "" \
  "^[a-z0-9]{2,6}$" "2–6 lowercase alphanumeric."
INITIALS="$REPLY"

prompt_val "Workload token" "olh" \
  "^[a-z0-9-]{2,10}$" "2–10 lowercase alphanumeric/hyphen."
WORKLOAD="$REPLY"

prompt_choice "Environment" "dev" "uat" "prod" -- "dev"; ENV="$REPLY"

# Region selection with presets
if [[ "$CLOUD" == "gcp" ]]; then
  REGION_PRESETS=("us-central1" "us-east1" "us-east4" "us-west1" "europe-west1" "europe-west2" "europe-west3" "europe-west4" "asia-southeast1" "asia-northeast1")
  REGION_DEFAULT="us-central1"
  REGION_RE="^[a-z]+-[a-z]+[0-9]$"
  REGION_HINT="Valid region e.g. us-central1."
  REGION_WORD="Google Cloud"
else
  REGION_PRESETS=("us-east-1" "us-east-2" "us-west-1" "us-west-2" "eu-west-1" "eu-west-2" "eu-central-1" "ap-southeast-1" "ap-southeast-2" "ap-northeast-1")
  REGION_DEFAULT="us-east-1"
  REGION_RE="^[a-z]{2}-[a-z]+-[0-9]$"
  REGION_HINT="Valid region e.g. us-east-1."
  REGION_WORD="AWS"
fi
echo ""
echo -e "    ${WHT}Select ${REGION_WORD} region:${RST}"
for i in "${!REGION_PRESETS[@]}"; do
  def_mark=""; [[ "${REGION_PRESETS[$i]}" == "$REGION_DEFAULT" ]] && def_mark=" ${GRY}(default)${RST}"
  printf "    [%2d] ${CYN}%s${RST}%b\n" "$(( i+1 ))" "${REGION_PRESETS[$i]}" "$def_mark"
done
echo -e "    [ C] ${GRY}Enter custom region${RST}"
echo ""
while true; do
  read -rp "    Select (1-${#REGION_PRESETS[@]} or C) [default: 1]: " reg_sel
  reg_sel="${reg_sel:-1}"
  if [[ "${reg_sel^^}" == "C" ]]; then
    prompt_val "Custom ${REGION_WORD} region" "" "$REGION_RE" "$REGION_HINT"
    REGION="$REPLY"; break
  elif [[ "$reg_sel" =~ ^[0-9]+$ ]] && (( reg_sel>=1 && reg_sel<=${#REGION_PRESETS[@]} )); then
    REGION="${REGION_PRESETS[$((reg_sel-1))]}"; break
  fi
  echo -e "    ${RED}${ERR}  Enter 1-${#REGION_PRESETS[@]} or C.${RST}"
done
echo -e "  ${GRN}${OK}  Region: ${REGION}${RST}"

PREFIX="${INITIALS}-${WORKLOAD}-${ENV}"
CREATE_DATE=$(date "+%Y-%m-%d")

if [[ "$CLOUD" == "gcp" ]]; then
  GCP_REGION="$REGION"
  TFSTATE_BUCKET="${INITIALS}-${WORKLOAD}-${ENV}-tfstate-gcs"

  # OLH spreads the cluster MIG over at least two zones, the same way it wants
  # two AZs on AWS. Default to the region's first two zones.
  echo ""
  echo -e "    ${WHT}Zones for the lakehouse managed instance group${RST} ${GRY}(at least two)${RST}"
  DEFAULT_ZONES="${GCP_REGION}-a,${GCP_REGION}-b"
  while true; do
    read -rp "    Zones, comma-separated [default: ${DEFAULT_ZONES}]: " _z
    _z="${_z:-$DEFAULT_ZONES}"
    IFS=',' read -r -a GCP_ZONES <<< "${_z// /}"
    if (( ${#GCP_ZONES[@]} < 2 )); then
      echo -e "    ${RED}${ERR}  OLH needs at least two zones so a Spot reclaim in one zone cannot take the cluster down.${RST}"
      continue
    fi
    _bad=""
    for z in "${GCP_ZONES[@]}"; do
      [[ "$z" =~ ^${GCP_REGION}-[a-z]$ ]] || _bad+=" $z"
    done
    if [[ -n "$_bad" ]]; then
      echo -e "    ${RED}${ERR}  Not zones of ${GCP_REGION}:${_bad}${RST}"
      continue
    fi
    break
  done
  echo -e "  ${GRN}${OK}  Zones: ${GCP_ZONES[*]}${RST}"
else
  TFSTATE_BUCKET="${INITIALS}-${WORKLOAD}-${ENV}-tfstate-s3"
fi

if [[ "$CLOUD" == "gcp" ]]; then

################################################################
#  GOOGLE CLOUD PROVISIONING PATH
#
#  Mirrors the AWS groups below, service for service, with two deliberate
#  differences:
#    * No stream resource. The GCP Private Preview covers CDC and SaaS
#      sources only; streaming, when it lands, is Kafka and GCS.
#    * Private Google Access on the subnetwork stands in for the S3 gateway
#      VPC endpoint.
################################################################

# ── Google Cloud Authentication ───────────────────────────────
section "Google Cloud Authentication"

echo -e "  ${WHT}Select Google Cloud authentication method:${RST}"
echo ""
echo -e "    [1] ${CYN}Current credentials${RST}   - use whatever 'gcloud auth' is already holding"
echo -e "    [2] ${CYN}User login${RST}            - run 'gcloud auth login' (opens a browser)"
echo -e "    [3] ${CYN}Service account key${RST}   - activate a JSON key file"
echo ""
while true; do
  read -rp "    Select (1-3) [default: 1]: " gauth_sel
  gauth_sel="${gauth_sel:-1}"
  case "$gauth_sel" in
    1) break ;;
    2)
      echo -e "  ${GRY}${ARW} gcloud auth login${RST}"
      if ! $DRY_RUN; then
        gcloud auth login || { echo -e "  ${RED}${ERR}  Login failed.${RST}"; exit 1; }
      fi
      break ;;
    3)
      prompt_val "Path to service account JSON key" "" "." "Enter a file path."
      GCP_KEY_FILE="$REPLY"
      if [[ ! -f "$GCP_KEY_FILE" ]]; then
        echo -e "    ${RED}${ERR}  No such file: ${GCP_KEY_FILE}${RST}"; continue
      fi
      echo -e "  ${GRY}${ARW} gcloud auth activate-service-account --key-file=...${RST}"
      if ! $DRY_RUN; then
        gcloud auth activate-service-account --key-file="$GCP_KEY_FILE" \
          || { echo -e "  ${RED}${ERR}  Could not activate that key.${RST}"; exit 1; }
      fi
      export GOOGLE_APPLICATION_CREDENTIALS="$GCP_KEY_FILE"
      break ;;
    *) echo -e "    ${RED}${ERR}  Enter 1-3.${RST}" ;;
  esac
done

# ── Verify identity ───────────────────────────────────────────
section "Verify Google Cloud Identity"
echo -e "  ${GRY}${ARW} gcloud auth list --filter=status:ACTIVE${RST}"
CALLER=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
if [[ -z "$CALLER" ]]; then
  echo -e "  ${RED}${ERR}  No active gcloud credentials. Run 'gcloud auth login' and re-run.${RST}"
  exit 1
fi
echo -e "  ${GRN}${OK}  Authenticated as: ${CALLER}${RST}"

# ── Project selection ─────────────────────────────────────────
section "Google Cloud Project"
echo -e "  ${GRY}${ARW} gcloud projects list${RST}"
PROJ_JSON=$(gcloud projects list --format=json 2>/dev/null || echo "[]")
PROJ_IDS=$(py "import sys,json; [print(p['projectId']) for p in json.load(sys.stdin)]" <<< "$PROJ_JSON")
PROJ_LBLS=$(py "import sys,json; [print(f\"{p['projectId']}  ({p.get('name','')})  #{p.get('projectNumber','')}\") for p in json.load(sys.stdin)]" <<< "$PROJ_JSON")
GCP_PROJECT_ID=""

if [[ -n "$PROJ_IDS" ]]; then
  pick_resource "Projects" "$PROJ_IDS" "$PROJ_LBLS"
  [[ -n "$REPLY" ]] && GCP_PROJECT_ID="$REPLY"
fi
if [[ -z "$GCP_PROJECT_ID" ]]; then
  prompt_val "Project ID" "" "^[a-z][a-z0-9-]{4,28}[a-z0-9]$" \
    "6-30 chars, lowercase letters, digits and hyphens, starting with a letter."
  GCP_PROJECT_ID="$REPLY"
fi

GCP_PROJECT_NUMBER=$(gcloud projects describe "$GCP_PROJECT_ID" \
  --format="value(projectNumber)" 2>/dev/null || true)
if [[ -z "$GCP_PROJECT_NUMBER" ]]; then
  echo -e "  ${RED}${ERR}  Cannot read project ${GCP_PROJECT_ID}. Check the ID and your permissions.${RST}"
  exit 1
fi
gcloud config set project "$GCP_PROJECT_ID" >/dev/null 2>&1 || true
echo -e "  ${GRN}${OK}  Project: ${GCP_PROJECT_ID}  (number ${GCP_PROJECT_NUMBER})${RST}"

# ── Application Default Credentials ───────────────────────────
# The Terraform google provider reads ADC, not the gcloud CLI credential. They
# are separate stores, and a wizard run that authenticated the CLI but not ADC
# fails later at 'terraform plan' with a confusing error.
section "Application Default Credentials"
if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  echo -e "  ${GRN}${OK}  GOOGLE_APPLICATION_CREDENTIALS is set - Terraform will use that key.${RST}"
elif gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo -e "  ${GRN}${OK}  ADC already configured.${RST}"
else
  echo -e "  ${YLW}${WRN}  No Application Default Credentials found.${RST}"
  echo -e "  ${GRY}      Terraform's google provider needs these separately from the gcloud CLI login.${RST}"
  if confirm "  Run 'gcloud auth application-default login' now?"; then
    if ! $DRY_RUN; then
      gcloud auth application-default login \
        || echo -e "  ${YLW}${WRN}  ADC login failed - Terraform steps may not run.${RST}"
    fi
  else
    echo -e "  ${YLW}${WRN}  Skipped. Terraform init/plan/apply will likely fail to authenticate.${RST}"
  fi
fi

# ── Qlik Talend Cloud tenant binding ──────────────────────────
section "Qlik Talend Cloud Tenant Binding"
echo -e "  ${GRY}  These come from Administration > Network integrations in your QTC tenant.${RST}"
echo ""
prompt_val "QTC tenant ID" "" "^[A-Za-z0-9_.:-]{4,128}$" \
  "4-128 chars: letters, digits, dot, colon, underscore or hyphen."
QTC_TENANT_ID="$REPLY"

echo ""
echo -e "  ${WHT}How will Qlik Talend Cloud authenticate into this project?${RST}"
echo -e "  ${YLW}  Note: Qlik has not published this for the Private Preview. Workload Identity${RST}"
echo -e "  ${YLW}  Federation is the GCP counterpart of the assume-role + ExternalId pattern${RST}"
echo -e "  ${YLW}  OLH uses on AWS, so it is the default here. Confirm against your preview${RST}"
echo -e "  ${YLW}  onboarding pack before treating this as final.${RST}"
echo ""
echo -e "    [1] ${CYN}Workload Identity Federation${RST}  ${GRY}(default)${RST}"
echo -e "    [2] ${CYN}Pre-authorized service account${RST}  ${GRY}- impersonation granted out of band${RST}"
echo ""
while true; do
  read -rp "    Select (1-2) [default: 1]: " qauth_sel
  qauth_sel="${qauth_sel:-1}"
  case "$qauth_sel" in
    1) QTC_AUTH_METHOD="workload_identity"
       prompt_val "QTC OIDC issuer URI" "https://auth.qlik.com/oauth/token" \
         "^https://.+" "Must be an https URL."
       QTC_OIDC_ISSUER="$REPLY"
       break ;;
    2) QTC_AUTH_METHOD="preauthorized_sa"; QTC_OIDC_ISSUER=""; break ;;
    *) echo -e "    ${RED}${ERR}  Enter 1 or 2.${RST}" ;;
  esac
done
echo -e "  ${GRN}${OK}  Auth method: ${QTC_AUTH_METHOD}${RST}"

# ── Required APIs ─────────────────────────────────────────────
section "Required Google Cloud APIs"
GCP_APIS=(
  compute.googleapis.com
  storage.googleapis.com
  cloudkms.googleapis.com
  secretmanager.googleapis.com
  biglake.googleapis.com
  bigquery.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
  sts.googleapis.com
)
echo -e "  ${GRY}${ARW} gcloud services enable ${GCP_APIS[*]}${RST}"
if ! $DRY_RUN; then
  if gcloud services enable "${GCP_APIS[@]}" --project="$GCP_PROJECT_ID" 2>/dev/null; then
    echo -e "  ${GRN}${OK}  APIs enabled (${#GCP_APIS[@]} services).${RST}"
  else
    echo -e "  ${YLW}${WRN}  Could not enable every API - you may lack serviceusage.services.enable.${RST}"
    echo -e "  ${GRY}      Ask a project owner to enable: ${GCP_APIS[*]}${RST}"
    confirm "  Continue anyway?" || { echo -e "${RED}  Aborted.${RST}"; exit 0; }
  fi
else
  echo -e "  ${YLW}[DRY-RUN] Would enable ${#GCP_APIS[@]} APIs.${RST}"
fi

################################################################
#  GROUP 2 - Network (VPC -> subnetwork -> NAT -> firewall)
################################################################
header "Group 2 of 5  -  Network"

# ── VPC network ──────────────────────────────────────────────
section "VPC Network"
echo -e "  ${GRY}${ARW} gcloud compute networks list${RST}"
NET_JSON=$(gcloud compute networks list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
NET_IDS=$(py "import sys,json; [print(n['name']) for n in json.load(sys.stdin)]" <<< "$NET_JSON")
NET_LBLS=$(py "import sys,json; [print(f\"{n['name']}  ({n.get('subnetMode','')})\") for n in json.load(sys.stdin)]" <<< "$NET_JSON")
NETWORK_NAME=""

if [[ -n "$NET_IDS" ]]; then
  pick_resource "VPC Networks" "$NET_IDS" "$NET_LBLS"
  [[ -n "$REPLY" ]] && NETWORK_NAME="$REPLY" && echo -e "  ${GRN}${OK}  Using network: ${NETWORK_NAME}${RST}"
fi
if [[ -z "$NETWORK_NAME" ]]; then
  prompt_val "New network name" "${PREFIX}-vpc" "^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$" \
    "Lowercase, starts with a letter, up to 63 chars."
  NETWORK_NAME="$REPLY"
  dry_exec "gcloud compute networks create ${NETWORK_NAME} --project=${GCP_PROJECT_ID} --subnet-mode=custom"
  echo -e "  ${GRN}${OK}  Created network: ${NETWORK_NAME}${RST}"
fi

# ── Subnetwork ───────────────────────────────────────────────
section "Subnetwork"
echo -e "  ${GRY}${ARW} gcloud compute networks subnets list --regions=${GCP_REGION}${RST}"
SUB_JSON=$(gcloud compute networks subnets list --project="$GCP_PROJECT_ID" \
  --regions="$GCP_REGION" --filter="network~${NETWORK_NAME}$" --format=json 2>/dev/null || echo "[]")
SUB_IDS=$(py "import sys,json; [print(s['name']) for s in json.load(sys.stdin)]" <<< "$SUB_JSON")
SUB_LBLS=$(py "import sys,json; [print(f\"{s['name']}  {s['ipCidrRange']}  PGA:{'on' if s.get('privateIpGoogleAccess') else 'OFF'}\") for s in json.load(sys.stdin)]" <<< "$SUB_JSON")
SUBNETWORK_NAME=""

if [[ -n "$SUB_IDS" ]]; then
  pick_resource "Subnetworks" "$SUB_IDS" "$SUB_LBLS"
  [[ -n "$REPLY" ]] && SUBNETWORK_NAME="$REPLY" && echo -e "  ${GRN}${OK}  Using subnetwork: ${SUBNETWORK_NAME}${RST}"
fi
if [[ -z "$SUBNETWORK_NAME" ]]; then
  prompt_val "New subnetwork name" "${PREFIX}-subnet" "^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$" \
    "Lowercase, starts with a letter, up to 63 chars."
  SUBNETWORK_NAME="$REPLY"
  prompt_val "Subnetwork CIDR" "10.20.0.0/20" \
    "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$" "Valid CIDR."
  SUBNETWORK_CIDR="$REPLY"
  dry_exec "gcloud compute networks subnets create ${SUBNETWORK_NAME} --project=${GCP_PROJECT_ID} --network=${NETWORK_NAME} --region=${GCP_REGION} --range=${SUBNETWORK_CIDR} --enable-private-ip-google-access"
  echo -e "  ${GRN}${OK}  Created subnetwork: ${SUBNETWORK_NAME}  (${SUBNETWORK_CIDR}, Private Google Access on)${RST}"
fi

# Read back the live CIDR and Private Google Access state, whichever path we
# took. Private Google Access is an OLH prerequisite - the GCP counterpart of
# the S3 gateway endpoint - so fix it here rather than failing at plan time.
if ! $DRY_RUN; then
  SUB_DESC=$(gcloud compute networks subnets describe "$SUBNETWORK_NAME" \
    --project="$GCP_PROJECT_ID" --region="$GCP_REGION" --format=json 2>/dev/null || echo "{}")
  SUBNETWORK_CIDR=$(py "import sys,json; print(json.load(sys.stdin).get('ipCidrRange',''))" <<< "$SUB_DESC")
  PGA=$(py "import sys,json; print('true' if json.load(sys.stdin).get('privateIpGoogleAccess') else 'false')" <<< "$SUB_DESC")
  if [[ "$PGA" != "true" ]]; then
    echo -e "  ${YLW}${WRN}  Private Google Access is off on ${SUBNETWORK_NAME}.${RST}"
    echo -e "  ${GRY}      OLH nodes reach Cloud Storage and the catalog over Google APIs; without${RST}"
    echo -e "  ${GRY}      it that traffic has to leave through the internet gateway.${RST}"
    if confirm "  Enable Private Google Access now?"; then
      gcloud compute networks subnets update "$SUBNETWORK_NAME" \
        --project="$GCP_PROJECT_ID" --region="$GCP_REGION" \
        --enable-private-ip-google-access >/dev/null 2>&1 \
        && echo -e "  ${GRN}${OK}  Private Google Access enabled.${RST}" \
        || echo -e "  ${RED}${ERR}  Could not enable it - Terraform will refuse to plan.${RST}"
    fi
  else
    echo -e "  ${GRN}${OK}  Private Google Access: on${RST}"
  fi
  echo -e "  ${GRN}${OK}  Subnetwork CIDR: ${SUBNETWORK_CIDR}${RST}"
else
  SUBNETWORK_CIDR="${SUBNETWORK_CIDR:-10.20.0.0/20}"
fi

# ── Cloud NAT ────────────────────────────────────────────────
# Lakehouse nodes run without external IPs. Private Google Access covers Google
# APIs; Cloud NAT is what lets the agent reach Qlik Talend Cloud itself, which
# is the GCP equivalent of the Internet Gateway on the AWS side.
section "Cloud Router and NAT"
NAT_ROUTER="${PREFIX}-router"
NAT_NAME="${PREFIX}-nat"
if gcloud compute routers describe "$NAT_ROUTER" --project="$GCP_PROJECT_ID" \
     --region="$GCP_REGION" >/dev/null 2>&1; then
  echo -e "  ${GRN}${OK}  Cloud Router exists: ${NAT_ROUTER}${RST}"
else
  echo -e "  ${YLW}${WRN}  Cloud Router not found - creating.${RST}"
  dry_exec "gcloud compute routers create ${NAT_ROUTER} --project=${GCP_PROJECT_ID} --network=${NETWORK_NAME} --region=${GCP_REGION}"
  echo -e "  ${GRN}${OK}  Created: ${NAT_ROUTER}${RST}"
fi
if gcloud compute routers nats describe "$NAT_NAME" --router="$NAT_ROUTER" \
     --project="$GCP_PROJECT_ID" --region="$GCP_REGION" >/dev/null 2>&1; then
  echo -e "  ${GRN}${OK}  Cloud NAT exists: ${NAT_NAME}${RST}"
else
  echo -e "  ${YLW}${WRN}  Cloud NAT not found - creating.${RST}"
  dry_exec "gcloud compute routers nats create ${NAT_NAME} --router=${NAT_ROUTER} --project=${GCP_PROJECT_ID} --region=${GCP_REGION} --auto-allocate-nat-external-ip --nat-all-subnet-ip-ranges"
  echo -e "  ${GRN}${OK}  Created: ${NAT_NAME}${RST}"
fi

# ── Firewall ─────────────────────────────────────────────────
# The GCP counterpart of the OLH security group: all TCP from inside the
# subnet so cluster nodes can talk to each other. Egress is allowed by GCP's
# implied default-allow-egress rule, so no egress rule is needed here.
section "Firewall Rule"
FIREWALL_RULE="${PREFIX}-allow-internal"
if gcloud compute firewall-rules describe "$FIREWALL_RULE" \
     --project="$GCP_PROJECT_ID" >/dev/null 2>&1; then
  echo -e "  ${GRN}${OK}  Firewall rule exists: ${FIREWALL_RULE}${RST}"
else
  echo -e "  ${YLW}${WRN}  Firewall rule not found - creating.${RST}"
  dry_exec "gcloud compute firewall-rules create ${FIREWALL_RULE} --project=${GCP_PROJECT_ID} --network=${NETWORK_NAME} --direction=INGRESS --action=ALLOW --rules=tcp:0-65535 --source-ranges=${SUBNETWORK_CIDR} --description='Qlik Open Lakehouse intra-cluster traffic'"
  echo -e "  ${GRN}${OK}  Created: ${FIREWALL_RULE}  (ingress from ${SUBNETWORK_CIDR})${RST}"
fi

################################################################
#  GROUP 3 - Security & Encryption (KMS -> service accounts)
################################################################
header "Group 3 of 5  -  Security & Encryption"

# ── Cloud KMS ────────────────────────────────────────────────
section "Cloud KMS Symmetric Key"
KMS_KEYRING="${PREFIX}-kr"
KMS_KEYNAME="${PREFIX}-key"
if gcloud kms keyrings describe "$KMS_KEYRING" --project="$GCP_PROJECT_ID" \
     --location="$GCP_REGION" >/dev/null 2>&1; then
  echo -e "  ${GRN}${OK}  Key ring exists: ${KMS_KEYRING}${RST}"
else
  echo -e "  ${YLW}${WRN}  Key ring not found - creating.${RST}"
  dry_exec "gcloud kms keyrings create ${KMS_KEYRING} --project=${GCP_PROJECT_ID} --location=${GCP_REGION}"
  echo -e "  ${GRN}${OK}  Created key ring: ${KMS_KEYRING}${RST}"
fi
if gcloud kms keys describe "$KMS_KEYNAME" --project="$GCP_PROJECT_ID" \
     --location="$GCP_REGION" --keyring="$KMS_KEYRING" >/dev/null 2>&1; then
  echo -e "  ${GRN}${OK}  Key exists: ${KMS_KEYNAME}${RST}"
else
  echo -e "  ${YLW}${WRN}  Key not found - creating.${RST}"
  dry_exec "gcloud kms keys create ${KMS_KEYNAME} --project=${GCP_PROJECT_ID} --location=${GCP_REGION} --keyring=${KMS_KEYRING} --purpose=encryption"
  echo -e "  ${GRN}${OK}  Created key: ${KMS_KEYNAME}${RST}"
fi
KMS_KEY_ID="projects/${GCP_PROJECT_ID}/locations/${GCP_REGION}/keyRings/${KMS_KEYRING}/cryptoKeys/${KMS_KEYNAME}"
echo -e "  ${GRN}${OK}  Key ID: ${KMS_KEY_ID}${RST}"

# Cloud Storage cannot write CMEK-encrypted objects until its own service agent
# can use the key. Without this, bucket creation with --default-encryption-key
# fails with a permission error that does not name the cause.
section "Cloud Storage Service Agent Grant"
GCS_AGENT=$(gcloud storage service-agent --project="$GCP_PROJECT_ID" 2>/dev/null || true)
if [[ -n "$GCS_AGENT" ]]; then
  echo -e "  ${GRY}${ARW} Granting cryptoKeyEncrypterDecrypter to ${GCS_AGENT}${RST}"
  if ! $DRY_RUN; then
    gcloud kms keys add-iam-policy-binding "$KMS_KEYNAME" \
      --project="$GCP_PROJECT_ID" --location="$GCP_REGION" --keyring="$KMS_KEYRING" \
      --member="serviceAccount:${GCS_AGENT}" \
      --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" >/dev/null 2>&1 \
      && echo -e "  ${GRN}${OK}  Storage service agent can use the key.${RST}" \
      || echo -e "  ${YLW}${WRN}  Grant failed - CMEK bucket creation may fail.${RST}"
  else
    echo -e "  ${YLW}[DRY-RUN] Would grant the storage service agent use of the key.${RST}"
  fi
else
  echo -e "  ${YLW}${WRN}  Could not resolve the Cloud Storage service agent.${RST}"
fi

# ── Service accounts ─────────────────────────────────────────
# Two accounts, on purpose. QTC impersonates the management account from
# outside the project; the node account is attached to the agent VM and the
# cluster MIG and holds the data-plane grants. Collapsing them into one is the
# mistake the AWS path used to make with mgmt_role_arn.
section "Service Accounts"

make_service_account() {
  local sa_id="$1" display="$2" email
  email="${sa_id}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
  if gcloud iam service-accounts describe "$email" \
       --project="$GCP_PROJECT_ID" >/dev/null 2>&1; then
    echo -e "  ${GRN}${OK}  ${display} exists: ${email}${RST}" >&2
  else
    echo -e "  ${YLW}${WRN}  ${display} not found - creating ${sa_id}${RST}" >&2
    if ! $DRY_RUN; then
      gcloud iam service-accounts create "$sa_id" --project="$GCP_PROJECT_ID" \
        --display-name="$display" >/dev/null 2>&1 \
        || { echo -e "  ${RED}${ERR}  Could not create ${sa_id}.${RST}" >&2; }
      echo -e "  ${GRN}${OK}  Created: ${email}${RST}" >&2
    else
      echo -e "  ${YLW}[DRY-RUN] Would create service account ${sa_id}${RST}" >&2
    fi
  fi
  echo "$email"
}

# Service account IDs are capped at 30 characters, so fall back to a short form
# when the prefix is long rather than letting gcloud reject the name.
MGMT_SA_ID="${PREFIX}-mgmt"
NODE_SA_ID="${PREFIX}-node"
if (( ${#MGMT_SA_ID} > 30 )); then
  MGMT_SA_ID="${INITIALS}-${ENV}-olh-mgmt"
  NODE_SA_ID="${INITIALS}-${ENV}-olh-node"
  echo -e "  ${GRY}  Prefix too long for a 30-char service account ID; using ${MGMT_SA_ID} / ${NODE_SA_ID}.${RST}"
fi

MGMT_SA=$(make_service_account "$MGMT_SA_ID" "Qlik OLH management (${PREFIX})")
NODE_SA=$(make_service_account "$NODE_SA_ID" "Qlik OLH nodes (${PREFIX})")

# Project roles the management account needs to stand up and run the cluster
# on your behalf. Terraform adds the narrower, resource-scoped grants.
section "Management Service Account Roles"
MGMT_ROLES=(
  roles/compute.instanceAdmin.v1
  roles/compute.networkUser
  roles/iam.serviceAccountUser
)
echo -e "  ${WHT}Granting to ${MGMT_SA}:${RST}"
for role in "${MGMT_ROLES[@]}"; do
  echo -e "  ${GRY}    ${ARW} ${role}${RST}"
  if ! $DRY_RUN; then
    gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
      --member="serviceAccount:${MGMT_SA}" --role="$role" \
      --condition=None >/dev/null 2>&1 \
      || echo -e "  ${YLW}${WRN}    Could not grant ${role}.${RST}"
  fi
done
$DRY_RUN && echo -e "  ${YLW}[DRY-RUN] Would grant ${#MGMT_ROLES[@]} roles.${RST}" \
         || echo -e "  ${GRN}${OK}  ${#MGMT_ROLES[@]} roles granted.${RST}"

################################################################
#  GROUP 4 - Storage (GCS buckets)
#
#  No streaming resource here: the GCP Private Preview covers CDC and SaaS
#  sources only. On AWS this group also creates a Kinesis stream.
################################################################
header "Group 4 of 5  -  Storage"

create_or_use_gcs_bucket() {
  local bname="$1" label="$2" cmek="$3" bn
  echo -e "  ${GRY}${ARW} gcloud storage buckets describe gs://${bname}${RST}" >&2
  if gcloud storage buckets describe "gs://${bname}" --project="$GCP_PROJECT_ID" >/dev/null 2>&1; then
    echo -e "  ${GRN}${OK}  ${label} exists: ${bname}${RST}" >&2
    if confirm "    Use existing '${bname}'?"; then echo "$bname"; return; fi
  else
    echo -e "  ${YLW}${WRN}  ${label} not found.${RST}" >&2
  fi
  prompt_val "    Bucket name for ${label}" "$bname" \
    "^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$" "Valid GCS bucket name."
  bn="$REPLY"
  if ! $DRY_RUN; then
    local enc=""
    [[ "$cmek" == "cmek" ]] && enc="--default-encryption-key=${KMS_KEY_ID}"
    local cb_out=""
    cb_out=$(gcloud storage buckets create "gs://${bn}" --project="$GCP_PROJECT_ID" \
      --location="$GCP_REGION" --uniform-bucket-level-access \
      --public-access-prevention $enc 2>&1) || {
      echo -e "  ${RED}${ERR}  Could not create ${bn}:${RST}" >&2
      echo -e "  ${GRY}      ${cb_out}${RST}" >&2
      exit 1; }
    gcloud storage buckets update "gs://${bn}" --project="$GCP_PROJECT_ID" \
      --update-labels="owner=${INITIALS},environment=${ENV},workload=qlik-olh,application=open-lakehouse,createdate=${CREATE_DATE},managedby=script" \
      >/dev/null 2>&1 || true
    echo -e "  ${GRN}${OK}  Created: ${bn}  (${cmek}, uniform access, public access prevented)${RST}" >&2
  else
    echo -e "  ${YLW}[DRY-RUN] Would create bucket: ${bn}${RST}" >&2
  fi
  echo "$bn"
}

section "Cloud Storage Buckets"
GCS_TABLE=$(create_or_use_gcs_bucket   "${PREFIX}-table-gcs"   "Iceberg table storage" "cmek")
GCS_LANDING=$(create_or_use_gcs_bucket "${PREFIX}-landing-gcs" "Landing bucket"        "cmek")
GCS_CONFIG=$(create_or_use_gcs_bucket  "${PREFIX}-config-gcs"  "Config bucket"         "cmek")
create_or_use_gcs_bucket "$TFSTATE_BUCKET" "TF State bucket" "google-managed" > /dev/null

# Terraform state benefits from versioning even though the lakehouse buckets
# do not need it.
if ! $DRY_RUN; then
  gcloud storage buckets update "gs://${TFSTATE_BUCKET}" --project="$GCP_PROJECT_ID" \
    --versioning >/dev/null 2>&1 || true
fi

else

# ── AWS Credentials Configuration ─────────────────────────────
section "AWS Authentication"

# List available profiles from ~/.aws/credentials and ~/.aws/config
get_aws_profiles() {
  local profiles=()
  if [[ -f "$HOME/.aws/credentials" ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^\[(.+)\]$ ]]; then
        profiles+=("${BASH_REMATCH[1]}")
      fi
    done < "$HOME/.aws/credentials"
  fi
  if [[ -f "$HOME/.aws/config" ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^\[profile[[:space:]]+(.+)\]$ ]]; then
        local p="${BASH_REMATCH[1]}"
        # Avoid duplicates
        local dup=false
        for existing in "${profiles[@]}"; do
          [[ "$existing" == "$p" ]] && dup=true && break
        done
        $dup || profiles+=("$p")
      fi
    done < "$HOME/.aws/config"
  fi
  echo "${profiles[@]}"
}

echo -e "  ${WHT}Select AWS authentication method:${RST}"
echo ""
echo -e "    [1] ${CYN}AWS Profile${RST}        – Use a named profile from ~/.aws/credentials"
echo -e "    [2] ${CYN}Access Key${RST}         – Enter Access Key ID + Secret Key"
echo -e "    [3] ${CYN}SSO Login${RST}          – Authenticate via AWS SSO"
echo -e "    [4] ${CYN}Current/Default${RST}    – Use existing environment or default profile"
echo -e "    [5] ${CYN}New Profile${RST}        – Create and save a new profile to ~/.aws/credentials"
echo -e "    [6] ${CYN}Load from File${RST}     – Import profiles from a credentials or CSV file"
echo ""

while true; do
  read -rp "    Select (1-6) [default: 4]: " auth_sel; auth_sel="${auth_sel:-4}"
  [[ "$auth_sel" =~ ^[1-6]$ ]] && break
  echo -e "    ${RED}${ERR}  Enter 1, 2, 3, 4, 5, or 6.${RST}"
done

case "$auth_sel" in
  1) # ── AWS Profile ──────────────────────────────────────────
    echo ""
    read -ra AVAIL_PROFILES <<< "$(get_aws_profiles)"
    if [[ ${#AVAIL_PROFILES[@]} -eq 0 ]]; then
      echo -e "  ${YLW}${WRN}  No profiles found in ~/.aws/credentials or ~/.aws/config${RST}"
      echo -e "  ${GRY}      Run 'aws configure' to set up a profile first.${RST}"
    else
      echo -e "  ${WHT}Available AWS profiles:${RST}"
      for i in "${!AVAIL_PROFILES[@]}"; do
        echo -e "    [$(( i+1 ))] ${WHT}${AVAIL_PROFILES[$i]}${RST}"
      done
      echo ""
      while true; do
        read -rp "    Select profile (1-${#AVAIL_PROFILES[@]}): " prof_sel
        if [[ "$prof_sel" =~ ^[0-9]+$ ]] && (( prof_sel>=1 && prof_sel<=${#AVAIL_PROFILES[@]} )); then
          break
        fi
        echo -e "    ${RED}${ERR}  Enter 1–${#AVAIL_PROFILES[@]}.${RST}"
      done
      export AWS_PROFILE="${AVAIL_PROFILES[$((prof_sel-1))]}"
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true
      echo -e "  ${GRN}${OK}  Using profile: ${AWS_PROFILE}${RST}"
    fi
    ;;

  2) # ── Access Key + Secret Key ──────────────────────────────
    echo ""
    echo -e "  ${WHT}Enter AWS credentials:${RST}"
    read -rsp "    AWS Access Key ID    : " aws_key_id; echo ""
    read -rsp "    AWS Secret Access Key: " aws_secret; echo ""
    read -rp  "    Session Token (optional, Enter to skip): " aws_token
    echo ""

    if [[ -z "$aws_key_id" || -z "$aws_secret" ]]; then
      echo -e "  ${RED}${ERR}  Access Key ID and Secret Key are required.${RST}"
      echo -e "  ${GRY}      Falling back to default credentials.${RST}"
    else
      export AWS_ACCESS_KEY_ID="$aws_key_id"
      export AWS_SECRET_ACCESS_KEY="$aws_secret"
      [[ -n "$aws_token" ]] && export AWS_SESSION_TOKEN="$aws_token"
      unset AWS_PROFILE 2>/dev/null || true
      echo -e "  ${GRN}${OK}  Access Key credentials set (Key ID: ${aws_key_id:0:4}****)${RST}"
    fi
    ;;

  3) # ── SSO Login ────────────────────────────────────────────
    echo ""
    read -ra AVAIL_PROFILES <<< "$(get_aws_profiles)"
    sso_profile=""
    if [[ ${#AVAIL_PROFILES[@]} -gt 0 ]]; then
      echo -e "  ${WHT}Available profiles for SSO:${RST}"
      for i in "${!AVAIL_PROFILES[@]}"; do
        echo -e "    [$(( i+1 ))] ${WHT}${AVAIL_PROFILES[$i]}${RST}"
      done
      echo -e "    [M] ${GRY}Enter profile name manually${RST}"
      echo ""
      while true; do
        read -rp "    Select (1-${#AVAIL_PROFILES[@]} or M): " sso_sel; sso_sel="${sso_sel^^}"
        if [[ "$sso_sel" == "M" ]]; then
          read -rp "    Enter SSO profile name: " sso_profile
          break
        elif [[ "$sso_sel" =~ ^[0-9]+$ ]] && (( sso_sel>=1 && sso_sel<=${#AVAIL_PROFILES[@]} )); then
          sso_profile="${AVAIL_PROFILES[$((sso_sel-1))]}"
          break
        fi
        echo -e "    ${RED}${ERR}  Enter 1–${#AVAIL_PROFILES[@]} or M.${RST}"
      done
    else
      read -rp "    Enter SSO profile name: " sso_profile
    fi

    if [[ -n "$sso_profile" ]]; then
      echo -e "\n  ${GRY}${ARW} Launching SSO login for profile '${sso_profile}' ...${RST}"
      echo -e "  ${YLW}  A browser window may open. Complete the SSO authentication there.${RST}"
      if aws sso login --profile "$sso_profile" 2>&1; then
        export AWS_PROFILE="$sso_profile"
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true
        echo -e "  ${GRN}${OK}  SSO login successful. Using profile: ${sso_profile}${RST}"
      else
        echo -e "  ${RED}${ERR}  SSO login failed.${RST}"
        echo -e "  ${GRY}      Verify your SSO configuration in ~/.aws/config${RST}"
        # Without this guard the script would silently continue with whatever
        # default credentials exist -- possibly deploying to the WRONG account.
        confirm "  Continue with default/environment credentials instead?" || {
          echo -e "  ${RED}Aborted.${RST}"; exit 1; }
      fi
    else
      echo -e "  ${YLW}${WRN}  No profile specified. Falling back to default credentials.${RST}"
    fi
    ;;

  4) # ── Current/Default ──────────────────────────────────────
    echo ""
    echo -e "  ${GRY}${ARW} Using current environment / default profile.${RST}"
    ;;

  5) # ── Configure New Profile ────────────────────────────────
    echo ""
    echo -e "  ${WHT}Configure a new AWS profile:${RST}"
    read -rp  "    Profile name          : " new_prof_name
    read -rsp "    AWS Access Key ID     : " new_prof_key; echo ""
    read -rsp "    AWS Secret Access Key : " new_prof_secret; echo ""
    read -rp  "    Default region [us-east-1]: " new_prof_region; new_prof_region="${new_prof_region:-us-east-1}"
    read -rp  "    Output format (json|text|table) [json]: " new_prof_output; new_prof_output="${new_prof_output:-json}"

    if [[ -z "$new_prof_name" || -z "$new_prof_key" || -z "$new_prof_secret" ]]; then
      echo -e "  ${RED}${ERR}  Profile name, Access Key ID, and Secret Key are all required.${RST}"
      echo -e "  ${GRY}      Falling back to default credentials.${RST}"
    else
      mkdir -p "$HOME/.aws"
      # Append to ~/.aws/credentials
      printf '\n[%s]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
        "$new_prof_name" "$new_prof_key" "$new_prof_secret" >> "$HOME/.aws/credentials"
      # Append to ~/.aws/config
      printf '\n[profile %s]\nregion = %s\noutput = %s\n' \
        "$new_prof_name" "$new_prof_region" "$new_prof_output" >> "$HOME/.aws/config"

      echo -e "  ${GRN}${OK}  Profile '${new_prof_name}' saved to ~/.aws/credentials and ~/.aws/config${RST}"
      export AWS_PROFILE="$new_prof_name"
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true
      echo -e "  ${GRN}${OK}  Using profile: ${AWS_PROFILE}${RST}"
    fi
    ;;

  6) # ── Load from File ───────────────────────────────────────
    echo ""
    read -rp "    Path to credentials or CSV file: " cred_file_path
    if [[ ! -f "$cred_file_path" ]]; then
      echo -e "  ${RED}${ERR}  File not found: ${cred_file_path}${RST}"
      echo -e "  ${GRY}      Falling back to default credentials.${RST}"
    else
      mkdir -p "$HOME/.aws"
      imported=0
      ext="${cred_file_path##*.}"

      if [[ "${ext,,}" == "csv" ]]; then
        # CSV format — AWS IAM export or custom: profile_name,access_key_id,secret_access_key[,region]
        echo -e "  ${GRY}${ARW} Parsing CSV file ...${RST}"
        {
          read -r header_line  # skip header
          while IFS=',' read -r col1 col2 col3 col4 col5; do
            # Strip quotes
            col1="${col1//\"/}"; col2="${col2//\"/}"; col3="${col3//\"/}"
            col4="${col4//\"/}"; col5="${col5//\"/}"
            # Determine column mapping from header
            if [[ -n "$col2" && -n "$col3" ]]; then
              csv_name="${col1:-imported}"
              csv_key="$col2"
              csv_secret="$col3"
              csv_region="${col4:-us-east-1}"
              if [[ -n "$csv_key" && -n "$csv_secret" && "$csv_key" != *"key"* ]]; then
                printf '\n[%s]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
                  "$csv_name" "$csv_key" "$csv_secret" >> "$HOME/.aws/credentials"
                printf '\n[profile %s]\nregion = %s\noutput = json\n' \
                  "$csv_name" "$csv_region" >> "$HOME/.aws/config"
                ((imported++))
                echo -e "    ${GRN}${OK}  Imported: ${csv_name}${RST}"
              fi
            fi
          done
        } < "$cred_file_path"
      else
        # INI-style credentials file — copy sections with aws_access_key_id
        echo -e "  ${GRY}${ARW} Parsing credentials file ...${RST}"
        current_section=""
        section_body=""
        while IFS= read -r line || [[ -n "$line" ]]; do
          if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            # Flush previous section
            if [[ -n "$current_section" && "$section_body" == *"aws_access_key_id"* ]]; then
              printf '\n[%s]\n%s\n' "$current_section" "$section_body" >> "$HOME/.aws/credentials"
              ((imported++))
              echo -e "    ${GRN}${OK}  Imported: ${current_section}${RST}"
            fi
            current_section="${BASH_REMATCH[1]}"
            section_body=""
          elif [[ -n "$current_section" ]]; then
            section_body+="$line"$'\n'
          fi
        done < "$cred_file_path"
        # Flush last section
        if [[ -n "$current_section" && "$section_body" == *"aws_access_key_id"* ]]; then
          printf '\n[%s]\n%s\n' "$current_section" "$section_body" >> "$HOME/.aws/credentials"
          ((imported++))
          echo -e "    ${GRN}${OK}  Imported: ${current_section}${RST}"
        fi
      fi

      if [[ $imported -gt 0 ]]; then
        echo -e "  ${GRN}${OK}  Imported ${imported} profile(s) from $(basename "$cred_file_path")${RST}"
        # Reload and list available profiles
        read -ra AVAIL_PROFILES <<< "$(get_aws_profiles)"
        echo -e "  ${WHT}Available profiles after import:${RST}"
        for i in "${!AVAIL_PROFILES[@]}"; do
          echo -e "    [$(( i+1 ))] ${WHT}${AVAIL_PROFILES[$i]}${RST}"
        done
        echo ""
        while true; do
          read -rp "    Select profile to use (1-${#AVAIL_PROFILES[@]}): " imp_sel
          if [[ "$imp_sel" =~ ^[0-9]+$ ]] && (( imp_sel>=1 && imp_sel<=${#AVAIL_PROFILES[@]} )); then
            break
          fi
          echo -e "    ${RED}${ERR}  Enter 1–${#AVAIL_PROFILES[@]}.${RST}"
        done
        export AWS_PROFILE="${AVAIL_PROFILES[$((imp_sel-1))]}"
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true
        echo -e "  ${GRN}${OK}  Using profile: ${AWS_PROFILE}${RST}"
      else
        echo -e "  ${YLW}${WRN}  No credential profiles found in file.${RST}"
        echo -e "  ${GRY}      Expected INI format with [profile] sections or CSV with key columns.${RST}"
      fi
    fi
    ;;
esac

# ── Verify AWS identity ──────────────────────────────────────
echo ""
echo -e "  ${GRY}${ARW} Verifying AWS authentication ...${RST}"
ACCT_ID="unknown"
CALLER="unknown"
IDENTITY=$(aws sts get-caller-identity --region "$REGION" --output json 2>/dev/null || true)
if [[ -n "$IDENTITY" ]]; then
  ACCT_ID=$(echo "$IDENTITY" | "$PY" -c "import sys,json; print(json.load(sys.stdin)['Account'])")
  CALLER=$(echo  "$IDENTITY" | "$PY" -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
  echo -e "  ${GRN}${OK}  Authenticated : ${CALLER}${RST}"
  echo -e "  ${GRN}${OK}  Account ID    : ${ACCT_ID}${RST}"
else
  echo -e "  ${YLW}${WRN}  AWS CLI not authenticated.${RST}"
  echo -e "  ${GRY}      Check your credentials and try again.${RST}"
  if ! $DRY_RUN; then
    # In LIVE mode an unknown account ID would poison every generated ARN
    # (arn:aws:kms:<region>:unknown:key/...) and the tfvars file. Hard stop.
    echo -e "  ${RED}${ERR}  Cannot continue a LIVE run without a verified AWS identity.${RST}"
    echo -e "  ${GRY}      Re-run after fixing credentials, or use --dry-run to preview.${RST}"
    exit 1
  fi
  echo -e "  ${YLW}      [DRY-RUN] Continuing with placeholder account ID.${RST}"
fi

echo -e "\n  ${GRN}Base prefix : ${PREFIX}${RST}"
echo -e "  ${GRN}Create date : ${CREATE_DATE}${RST}"

# QTC tenant binding. Collected before any IAM work, because the management
# role's trust policy is built from these two values. Without them QTC has
# nothing it can assume and the network integration never connects.
section "Qlik Talend Cloud Tenant Binding"
echo -e "  ${GRY}  Both values come from Administration > Network integrations in QTC,${RST}"
echo -e "  ${GRY}  on the screen where you create the integration.${RST}"
echo ""
prompt_val "QTC ExternalId" "" "^[A-Za-z0-9_.:/=+-]{4,1224}$" "4-1224 chars: letters, digits and _.:/=+- (the sts:ExternalId format)."
QTC_EXTERNAL_ID="$REPLY"

prompt_val "Qlik proxy role ARN" "" "^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user)/.+$" "An IAM role or user ARN, e.g. arn:aws:iam::<qlik-account>:role/qlik-proxy-assume-role."
QLIK_PROXY_ROLE_ARN="$REPLY"
echo -e "  ${GRN}${OK}  Management role will trust ${QLIK_PROXY_ROLE_ARN} with your ExternalId.${RST}"

################################################################
#  PRE-FLIGHT — Permission & Duplicate Guard
################################################################
header "Pre-flight — Permission Check & Duplicate Guard"

# ── IAM Permission Checks ─────────────────────────────────────
section "IAM Permission Verification"
declare -A PERMS=(
  ["EC2"]="ec2:CreateVpc ec2:CreateSubnet ec2:CreateSecurityGroup ec2:DescribeVpcs ec2:DescribeSubnets"
  ["S3"]="s3:CreateBucket s3:PutBucketPolicy s3:PutEncryptionConfiguration s3:PutPublicAccessBlock"
  ["IAM"]="iam:CreateRole iam:CreateInstanceProfile iam:AttachRolePolicy iam:AddRoleToInstanceProfile"
  ["KMS"]="kms:CreateKey kms:CreateAlias kms:TagResource kms:DescribeKey"
  ["Kinesis"]="kinesis:CreateStream kinesis:DescribeStream kinesis:ListStreams"
  ["Glue"]="glue:CreateDatabase glue:GetDatabase"
  ["STS"]="sts:GetCallerIdentity"
)
PREFLIGHT_OK=true
# simulate-principal-policy needs an IAM role or user ARN as the policy source.
# A session ARN (arn:aws:sts::<acct>:assumed-role/<Role>/<session>) is not one,
# so reduce it to the underlying role before asking.
POLICY_SRC=""
case "$CALLER" in
  arn:*:iam::*:role/*|arn:*:iam::*:user/*) POLICY_SRC="$CALLER" ;;
  arn:*:sts::*:assumed-role/*)
    _sim_part="$(cut -d: -f2 <<< "$CALLER")"
    _sim_role="${CALLER#*:assumed-role/}"; _sim_role="${_sim_role%%/*}"
    POLICY_SRC="arn:${_sim_part}:iam::${ACCT_ID}:role/${_sim_role}" ;;
esac

if [[ -z "$POLICY_SRC" ]]; then
  echo -e "  ${YLW}${WRN}  Could not verify permissions: '${CALLER}' is not an IAM role or user ARN.${RST}"
  echo -e "  ${GRY}      Nothing was measured -- creation steps may still fail on access denied.${RST}"
else
  echo -e "  ${GRY}      Policy source: ${POLICY_SRC}${RST}"
  for svc in EC2 S3 IAM KMS Kinesis Glue STS; do
    echo -e "  ${GRY}${ARW} Simulating ${svc} permissions via iam:SimulatePrincipalPolicy${RST}"
    read -ra _sim_actions <<< "${PERMS[$svc]}"
    if _sim_denied=$(aws iam simulate-principal-policy \
          --policy-source-arn "$POLICY_SRC" \
          --action-names "${_sim_actions[@]}" \
          --query "EvaluationResults[?EvalDecision!='allowed'].EvalActionName" \
          --output text 2>/dev/null); then
      _sim_denied=$(tr '\t' ' ' <<< "$_sim_denied")
      if [[ -z "${_sim_denied// /}" || "$_sim_denied" == "None" ]]; then
        echo -e "  ${GRN}${OK}  ${svc}: all required permissions granted${RST}"
      else
        echo -e "  ${RED}${ERR}  ${svc}: denied - ${_sim_denied}${RST}"
        PREFLIGHT_OK=false
      fi
    else
      echo -e "  ${YLW}${WRN}  ${svc}: could not verify (iam:SimulatePrincipalPolicy denied or unavailable)${RST}"
    fi
  done
fi

if ! $PREFLIGHT_OK; then
  echo ""
  echo -e "  ${RED}${ERR}  Required actions are denied for ${POLICY_SRC}.${RST}"
  echo -e "  ${GRY}      The create steps below will fail on those services.${RST}"
  confirm "  Continue anyway?" || { echo -e "${RED}  Aborted.${RST}"; exit 0; }
fi

# CloudTrail check (non-blocking)
echo -e "  ${GRY}${ARW} Checking CloudTrail audit logging status${RST}"
CT_STATUS=$(aws cloudtrail get-trail-status --name default --region "$REGION" \
  --query 'IsLogging' --output text 2>/dev/null || echo "false")
if [[ "$CT_STATUS" == "true" ]]; then
  echo -e "  ${GRN}${OK}  CloudTrail: logging active${RST}"
else
  echo -e "  ${YLW}${WRN}  CloudTrail: not active or trail not found (non-blocking)${RST}"
fi

# ── Duplicate Resource Guard ──────────────────────────────────
section "Duplicate Resource Guard"
echo -e "  ${GRY}${ARW} Scanning for existing resources with prefix: ${PREFIX}${RST}"
DUPES_FOUND=false

# S3 check
EXISTING_BUCKETS=$(aws s3api list-buckets \
  --query "Buckets[?starts_with(Name,'${PREFIX}')].Name" \
  --output text 2>/dev/null || echo "")
if [[ -n "$EXISTING_BUCKETS" ]]; then
  echo -e "  ${YLW}${WRN}  S3 buckets already exist with this prefix:${RST}"
  echo "$EXISTING_BUCKETS" | tr '\t' '\n' | while read -r b; do
    echo -e "       ${b}"; done
  DUPES_FOUND=true
else
  echo -e "  ${GRN}${OK}  No S3 buckets found with prefix ${PREFIX}${RST}"
fi

# VPC check
EXISTING_VPC=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=${PREFIX}-vpc" \
  --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "None")
if [[ "$EXISTING_VPC" != "None" && -n "$EXISTING_VPC" ]]; then
  echo -e "  ${YLW}${WRN}  VPC already exists: ${EXISTING_VPC} — will reuse${RST}"
  DUPES_FOUND=true
else
  echo -e "  ${GRN}${OK}  No VPC found named ${PREFIX}-vpc${RST}"
fi

# IAM Role check
EXISTING_ROLE=$(aws iam get-role --role-name "${PREFIX}-ec2-role-iam" \
  --query 'Role.Arn' --output text 2>/dev/null || echo "")
if [[ -n "$EXISTING_ROLE" ]]; then
  echo -e "  ${YLW}${WRN}  IAM role exists: ${EXISTING_ROLE} — will reuse${RST}"
  DUPES_FOUND=true
else
  echo -e "  ${GRN}${OK}  No IAM role found for prefix${RST}"
fi

$DUPES_FOUND && echo "" && \
  echo -e "  ${YLW}${WRN}  Some resources already exist. They will be reused or you'll be prompted to create new ones.${RST}"
! $DUPES_FOUND && echo -e "  ${GRN}${OK}  No duplicate resources found. Safe to proceed.${RST}"

if ! confirm "  Continue with deployment?"; then
  echo -e "${RED}  Aborted.${RST}"; exit 0
fi

# ── Drift-only mode shortcut ─────────────────────────────────
if $DRIFT_ONLY; then
  header "Drift Detection — ${PREFIX}"
  if [[ ! -f "$TFVARS" ]]; then
    echo -e "  ${RED}${ERR}  terraform.tfvars not found. Run a deployment first.${RST}"; exit 1; fi

  echo -e "  ${GRY}Comparing ${TFVARS} against live AWS state ...${RST}\n"
  printf "  %-30s %-35s %-35s %s\n" "Resource" "Expected (tfvars)" "Live AWS" "Status"
  echo "  $SEP"

  check_drift() {
    local res="$1" exp="$2" act="$3"
    local st; [[ "$exp" == "$act" ]] && st="${GRN}MATCH${RST}" || st="${RED}DRIFT${RST}"
    printf "  %-30s %-35s %-35s " "$res" "${exp:0:33}" "${act:0:33}"
    echo -e "$st"
  }

  TF_VPC=$(grep 'vpc_id' "$TFVARS" | cut -d'"' -f2 || echo "")
  LIVE_VPC=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=${PREFIX}-vpc" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "N/A")
  check_drift "VPC ID" "$TF_VPC" "$LIVE_VPC"

  TF_SG=$(grep 'security_group_id' "$TFVARS" | cut -d'"' -f2 || echo "")
  LIVE_SG=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag:Name,Values=${PREFIX}-sg" \
    --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "N/A")
  check_drift "Security Group" "$TF_SG" "$LIVE_SG"

  TF_KINESIS=$(grep 'kinesis_stream_name' "$TFVARS" | cut -d'"' -f2 || echo "")
  LIVE_KINESIS=$(aws kinesis describe-stream-summary \
    --stream-name "${PREFIX}-stream-kinesis" --region "$REGION" \
    --query "StreamDescriptionSummary.StreamName" --output text 2>/dev/null || echo "NOT_FOUND")
  check_drift "Kinesis Stream" "$TF_KINESIS" "$LIVE_KINESIS"

  # Tag drift check on S3 iceberg bucket
  LIVE_OWNER=$(aws s3api get-bucket-tagging --bucket "${PREFIX}-iceberg-s3" 2>/dev/null | \
    "$PY" -c "import sys,json; t={x['Key']:x['Value'] for x in json.load(sys.stdin)['TagSet']}; print(t.get('Owner','N/A'))" 2>/dev/null || echo "N/A")
  check_drift "Tag: Owner" "$INITIALS" "$LIVE_OWNER"

  LIVE_ENV=$(aws s3api get-bucket-tagging --bucket "${PREFIX}-iceberg-s3" 2>/dev/null | \
    "$PY" -c "import sys,json; t={x['Key']:x['Value'] for x in json.load(sys.stdin)['TagSet']}; print(t.get('Environment','N/A'))" 2>/dev/null || echo "N/A")
  check_drift "Tag: Environment" "$ENV" "$LIVE_ENV"

  echo ""; echo -e "  ${GRN}Drift detection complete.${RST}"
  exit 0
fi

# ── Teardown mode ─────────────────────────────────────────────
if $TEARDOWN; then
  header "TEARDOWN — ${PREFIX}"
  echo -e "  ${RED}${WRN}  This will permanently destroy all OLH resources for: ${PREFIX}${RST}\n"
  confirm "  Type 'y' to confirm teardown" || { echo "Aborted."; exit 0; }

  # Read the ACTUAL resource names from terraform.tfvars when present.
  # The user may have customized names during deployment -- recomputing
  # defaults from PREFIX would orphan renamed resources. X="${v:-$X}" rather
  # than [[ -n ]] && X=...: an absent key must not trip set -e.
  TD_ICEBERG="${PREFIX}-iceberg-s3"
  TD_LANDING="${PREFIX}-landing-s3"
  TD_CONFIG="${PREFIX}-config-s3"
  TD_KINESIS="${PREFIX}-stream-kinesis"
  if [[ -f "$TFVARS" ]]; then
    v=$(grep -E '^s3_bucket_name[[:space:]]*='      "$TFVARS" | head -1 | cut -d'"' -f2 || true); TD_ICEBERG="${v:-$TD_ICEBERG}"
    v=$(grep -E '^s3_landing_bucket[[:space:]]*='   "$TFVARS" | head -1 | cut -d'"' -f2 || true); TD_LANDING="${v:-$TD_LANDING}"
    v=$(grep -E '^s3_config_bucket[[:space:]]*='    "$TFVARS" | head -1 | cut -d'"' -f2 || true); TD_CONFIG="${v:-$TD_CONFIG}"
    v=$(grep -E '^kinesis_stream_name[[:space:]]*=' "$TFVARS" | head -1 | cut -d'"' -f2 || true); TD_KINESIS="${v:-$TD_KINESIS}"
  else
    echo -e "  ${YLW}${WRN}  ${TFVARS} not found -- using default names derived from prefix.${RST}"
  fi

  echo -e "\n  ${GRY}${ARW} terraform -chdir=${TF_PATH} destroy -auto-approve -var-file=terraform.tfvars${RST}"
  dry_exec "terraform -chdir=\"${TF_PATH}\" destroy -auto-approve -var-file=terraform.tfvars"

  section "Removing resources not managed by Terraform"
  for bucket in "${TD_ICEBERG}" "${TD_LANDING}" "${TD_CONFIG}"; do
    echo -e "  ${GRY}${ARW} Emptying and removing S3 bucket: ${bucket}${RST}"
    dry_exec "aws s3 rm s3://${bucket} --recursive --region ${REGION} 2>/dev/null || true"
    dry_exec "aws s3api delete-bucket --bucket ${bucket} --region ${REGION} 2>/dev/null || true"
    echo -e "  ${GRN}${OK}  Removed: ${bucket}${RST}"
  done

  echo -e "  ${GRY}${ARW} Deleting Kinesis stream: ${TD_KINESIS}${RST}"
  dry_exec "aws kinesis delete-stream --stream-name ${TD_KINESIS} --region ${REGION} 2>/dev/null || true"

  echo -e "  ${GRY}${ARW} Removing instance profile role association${RST}"
  dry_exec "aws iam remove-role-from-instance-profile \
    --instance-profile-name ${PREFIX}-instance-profile \
    --role-name ${PREFIX}-ec2-role-iam 2>/dev/null || true"
  dry_exec "aws iam delete-instance-profile \
    --instance-profile-name ${PREFIX}-instance-profile 2>/dev/null || true"

  echo ""
  echo -e "  ${GRN}${OK}  Teardown complete for prefix: ${PREFIX}${RST}"
  exit 0
fi

################################################################
#  GROUP 2 – Network (VPC → Subnets → Security Group)
################################################################
header "Group 2 of 5  –  Network"

# ── VPC ──────────────────────────────────────────────────────
section "VPC"
echo -e "  ${GRY}${ARW} aws ec2 describe-vpcs --region ${REGION}${RST}"
VPC_JSON=$(aws ec2 describe-vpcs --region "$REGION" \
  --query "Vpcs[*].{Id:VpcId,CIDR:CidrBlock,Name:Tags[?Key=='Name']|[0].Value}" \
  --output json 2>/dev/null || echo "[]")

VPC_IDS=$(py    "import sys,json; [print(v['Id']) for v in json.load(sys.stdin)]" <<< "$VPC_JSON")
VPC_LABELS=$(py "import sys,json; [print(f\"{v['Id']}  CIDR:{v['CIDR']}  Name:{v.get('Name') or '(unnamed)'}\") for v in json.load(sys.stdin)]" <<< "$VPC_JSON")
VPC_ID=""; VPC_CIDR=""

if [[ -n "$VPC_IDS" ]]; then
  pick_resource "VPCs" "$VPC_IDS" "$VPC_LABELS"
  if [[ -n "$REPLY" ]]; then
    VPC_ID="$REPLY"
    VPC_CIDR=$(py "import sys,json; v=[x for x in json.load(sys.stdin) if x['Id']=='${VPC_ID}']; print(v[0]['CIDR'])" <<< "$VPC_JSON")
    echo -e "  ${GRN}${OK}  Using VPC: ${VPC_ID}  (${VPC_CIDR})${RST}"
  fi
fi

if [[ -z "$VPC_ID" ]]; then
  echo -e "  ${YLW}  No VPC selected — creating new.${RST}"
  prompt_val "CIDR for new VPC" "10.0.0.0/16" \
    "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$" "Valid CIDR."
  VPC_CIDR="$REPLY"
  echo -e "  ${GRY}${ARW} aws ec2 create-vpc --cidr-block ${VPC_CIDR}${RST}"
  if ! $DRY_RUN; then
    VPC_OUT=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --region "$REGION" \
      --tag-specifications "$(tag_spec vpc "${PREFIX}-vpc" "$INITIALS" "$ENV" "$CREATE_DATE")" \
      --output json)
    VPC_ID=$(py "import sys,json; print(json.load(sys.stdin)['Vpc']['VpcId'])" <<< "$VPC_OUT")
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$REGION"
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support    --region "$REGION"
    echo -e "  ${GRN}${OK}  Created VPC: ${VPC_ID}${RST}"
  else
    VPC_ID="vpc-DRYRUN"; echo -e "  ${YLW}[DRY-RUN] Would create VPC with CIDR ${VPC_CIDR}${RST}"
  fi
fi

# ── Subnets ──────────────────────────────────────────────────
section "Subnets & Availability Zones"
echo -e "  ${GRY}${ARW} aws ec2 describe-subnets --filter vpc-id=${VPC_ID}${RST}"
SUB_JSON=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query "Subnets[*].{Id:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}" \
  --output json 2>/dev/null || echo "[]")

SUB_IDS=$(py    "import sys,json; [print(s['Id']) for s in json.load(sys.stdin)]" <<< "$SUB_JSON")
SUB_LABELS=$(py "import sys,json; [print(f\"{s['Id']}  AZ:{s['AZ']}  CIDR:{s['CIDR']}\") for s in json.load(sys.stdin)]" <<< "$SUB_JSON")
declare -a SUBNET_AZ_PAIRS=()
ADD_MORE=true

if [[ -n "$SUB_IDS" ]]; then
  echo -e "  ${YLW}Subnets found in VPC.${RST}"
  while $ADD_MORE; do
    pick_resource "Subnets" "$SUB_IDS" "$SUB_LABELS"
    if [[ -n "$REPLY" ]]; then
      SUB_ID="$REPLY"
      AZ=$(py "import sys,json; s=[x for x in json.load(sys.stdin) if x['Id']=='${SUB_ID}']; print(s[0]['AZ'])" <<< "$SUB_JSON")
      SUBNET_AZ_PAIRS+=("${SUB_ID}|${AZ}")
      echo -e "    ${GRN}${OK}  Added: ${SUB_ID}  AZ:${AZ}${RST}"
    else
      prompt_val "CIDR for new subnet" "" \
        "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$" "Valid CIDR."
      NC="$REPLY"
      prompt_val "AZ (e.g. ${REGION}a)" "" "^[a-z]{2}-[a-z]+-[0-9][a-z]$" "Valid AZ."
      NA="$REPLY"
      echo -e "  ${GRY}${ARW} aws ec2 create-subnet ...${RST}"
      if ! $DRY_RUN; then
        NS=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$NC" \
          --availability-zone "$NA" --region "$REGION" \
          --tag-specifications "$(tag_spec subnet "${PREFIX}-subnet" "$INITIALS" "$ENV" "$CREATE_DATE")" \
          --output json | py "import sys,json; print(json.load(sys.stdin)['Subnet']['SubnetId'])")
        SUBNET_AZ_PAIRS+=("${NS}|${NA}")
        echo -e "    ${GRN}${OK}  Created: ${NS}  AZ:${NA}${RST}"
      else
        SUBNET_AZ_PAIRS+=("subnet-DRYRUN|${NA}")
        echo -e "    ${YLW}[DRY-RUN] Would create subnet ${NC} in ${NA}${RST}"
      fi
    fi
    confirm "    Add another subnet?" || ADD_MORE=false
  done
else
  echo -e "  ${YLW}${WRN}  No subnets found — creating at least one.${RST}"
  ADD_MORE=true
  while $ADD_MORE; do
    prompt_val "CIDR for new subnet" "" \
      "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$" "Valid CIDR."
    NC="$REPLY"
    prompt_val "AZ (e.g. ${REGION}a)" "" "^[a-z]{2}-[a-z]+-[0-9][a-z]$" "Valid AZ."
    NA="$REPLY"
    if ! $DRY_RUN; then
      NS=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$NC" \
        --availability-zone "$NA" --region "$REGION" \
        --tag-specifications "$(tag_spec subnet "${PREFIX}-subnet" "$INITIALS" "$ENV" "$CREATE_DATE")" \
        --output json | py "import sys,json; print(json.load(sys.stdin)['Subnet']['SubnetId'])")
      SUBNET_AZ_PAIRS+=("${NS}|${NA}")
      echo -e "    ${GRN}${OK}  Created: ${NS}  AZ:${NA}${RST}"
    else
      SUBNET_AZ_PAIRS+=("subnet-DRYRUN-${NA}|${NA}")
      echo -e "    ${YLW}[DRY-RUN] Would create subnet ${NC} in ${NA}${RST}"
    fi
    confirm "    Add another subnet?" || ADD_MORE=false
  done
fi

# ── Subnet prerequisite check ────────────────────────────────
# OLH wants at least two subnets, in two different Availability Zones, each of
# them public: auto-assign public IP on, with a route to an Internet Gateway.
# The picker above accepts anything, so verify it here rather than discovering
# the problem when a cluster fails to launch.
section "Subnet Prerequisite Check"
declare -A _AZ_SEEN=()
SUBNET_IDS_CSV=""
NONPUBLIC=""
for pair in "${SUBNET_AZ_PAIRS[@]}"; do
  sub_id="${pair%%|*}"; sub_az="${pair##*|}"
  _AZ_SEEN["$sub_az"]=1
  SUBNET_IDS_CSV+="${SUBNET_IDS_CSV:+,}${sub_id}"
  if ! $DRY_RUN; then
    map_pub=$(aws ec2 describe-subnets --subnet-ids "$sub_id" --region "$REGION" --query "Subnets[0].MapPublicIpOnLaunch" --output text 2>/dev/null || echo "False")
    [[ "$map_pub" != "True" ]] && NONPUBLIC+=" ${sub_id}"
  fi
done

AZ_COUNT=${#_AZ_SEEN[@]}
if (( ${#SUBNET_AZ_PAIRS[@]} < 2 )); then
  echo -e "  ${RED}${ERR}  Only ${#SUBNET_AZ_PAIRS[@]} subnet selected. OLH requires at least two.${RST}"
  confirm "  Continue anyway (Terraform will refuse to plan)?" || { echo -e "${RED}  Aborted.${RST}"; exit 0; }
elif (( AZ_COUNT < 2 )); then
  echo -e "  ${RED}${ERR}  The selected subnets span only ${AZ_COUNT} Availability Zone.${RST}"
  echo -e "  ${GRY}      OLH spreads the cluster over two AZs; a single-AZ selection cannot survive an AZ event.${RST}"
  confirm "  Continue anyway (Terraform will refuse to plan)?" || { echo -e "${RED}  Aborted.${RST}"; exit 0; }
else
  echo -e "  ${GRN}${OK}  ${#SUBNET_AZ_PAIRS[@]} subnets across ${AZ_COUNT} Availability Zones.${RST}"
fi

if [[ -n "$NONPUBLIC" ]]; then
  echo -e "  ${YLW}${WRN}  These subnets do not auto-assign public IPs:${NONPUBLIC}${RST}"
  echo -e "  ${GRY}      OLH cluster subnets must be public. Terraform will refuse to plan otherwise.${RST}"
  if confirm "  Enable auto-assign public IP on them now?"; then
    for sn in $NONPUBLIC; do
      aws ec2 modify-subnet-attribute --subnet-id "$sn" --region "$REGION" --map-public-ip-on-launch &>/dev/null && echo -e "  ${GRN}${OK}  ${sn} updated.${RST}" || echo -e "  ${RED}${ERR}  Could not update ${sn}.${RST}"
    done
  fi
else
  $DRY_RUN || echo -e "  ${GRN}${OK}  All selected subnets auto-assign public IPs.${RST}"
fi

# ── S3 gateway VPC endpoint ──────────────────────────────────
# An OLH network prerequisite. AWS allows one gateway endpoint per VPC per
# service, so find an existing one and hand it to Terraform; otherwise leave
# the tfvars entry empty and let Terraform create it.
section "S3 Gateway VPC Endpoint"
S3_VPCE_ID=""
if ! $DRY_RUN; then
  echo -e "  ${GRY}${ARW} aws ec2 describe-vpc-endpoints --filters vpc-id=${VPC_ID} service=s3${RST}"
  S3_VPCE_ID=$(aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${REGION}.s3" --query "VpcEndpoints[?VpcEndpointType=='Gateway']|[0].VpcEndpointId" --output text 2>/dev/null || echo "")
  [[ "$S3_VPCE_ID" == "None" ]] && S3_VPCE_ID=""
fi
if [[ -n "$S3_VPCE_ID" ]]; then
  echo -e "  ${GRN}${OK}  Existing gateway endpoint: ${S3_VPCE_ID}  (Terraform will reuse it)${RST}"
else
  echo -e "  ${YLW}${WRN}  No S3 gateway endpoint in this VPC - Terraform will create one.${RST}"
fi

# ── Security Group ────────────────────────────────────────────
section "Security Group"
echo -e "  ${GRY}${ARW} aws ec2 describe-security-groups --filter vpc-id=${VPC_ID} name=*${PREFIX}*${RST}"
SG_JSON=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=*${PREFIX}*" \
  --query "SecurityGroups[*].{Id:GroupId,Name:GroupName}" \
  --output json 2>/dev/null || echo "[]")
SG_IDS=$(py    "import sys,json; [print(s['Id']) for s in json.load(sys.stdin)]" <<< "$SG_JSON")
SG_LABELS=$(py "import sys,json; [print(f\"{s['Id']}  {s['Name']}\") for s in json.load(sys.stdin)]" <<< "$SG_JSON")
SG_ID=""

if [[ -n "$SG_IDS" ]]; then
  pick_resource "Security Groups" "$SG_IDS" "$SG_LABELS"
  [[ -n "$REPLY" ]] && SG_ID="$REPLY" && echo -e "  ${GRN}${OK}  Using SG: ${SG_ID}${RST}"
fi
if [[ -z "$SG_ID" ]]; then
  echo -e "  ${YLW}  Creating ${PREFIX}-sg (OLH rules: inbound all TCP from the VPC CIDR)${RST}"
  if ! $DRY_RUN; then
    SG_ID=$(aws ec2 create-security-group \
      --group-name "${PREFIX}-sg" \
      --description "Qlik OLH ${PREFIX}" \
      --vpc-id "$VPC_ID" --region "$REGION" \
      --tag-specifications "$(tag_spec security-group "${PREFIX}-sg" "$INITIALS" "$ENV" "$CREATE_DATE")" \
      --output json | py "import sys,json; print(json.load(sys.stdin)['GroupId'])")
    # OLH requires inbound All TCP from the VPC CIDR so cluster nodes and the
    # network integration agent can reach each other. This rule was missing,
    # which left the cluster unable to form.
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
      --ip-permissions "IpProtocol=tcp,FromPort=0,ToPort=65535,IpRanges=[{CidrIp=${VPC_CIDR}}]" &>/dev/null || true
    # Outbound is already unrestricted: AWS attaches an allow-all egress rule
    # to every new security group, which is what OLH asks for.
    echo -e "  ${GRN}${OK}  Created SG: ${SG_ID}  (ingress all TCP from ${VPC_CIDR}, egress all)${RST}"
  else
    SG_ID="sg-DRYRUN"
    echo -e "  ${YLW}[DRY-RUN] Would create security group ${PREFIX}-sg${RST}"
  fi
fi

################################################################
#  GROUP 3 – Security & Encryption (KMS → IAM → Instance Profile)
################################################################
header "Group 3 of 5  –  Security & Encryption"

# ── KMS ──────────────────────────────────────────────────────
section "KMS Symmetric Key"
echo -e "  ${GRY}${ARW} aws kms list-aliases --query contains('${PREFIX}')${RST}"
KMS_JSON=$(aws kms list-aliases --region "$REGION" \
  --query "Aliases[?contains(AliasName,'${PREFIX}')].{Alias:AliasName,KeyId:TargetKeyId}" \
  --output json 2>/dev/null || echo "[]")
KMS_IDS=$(py    "import sys,json; [print(k['KeyId']) for k in json.load(sys.stdin) if k.get('KeyId')]" <<< "$KMS_JSON")
KMS_LABELS=$(py "import sys,json; [print(f\"{k.get('KeyId','')}  {k.get('Alias','')}\") for k in json.load(sys.stdin)]" <<< "$KMS_JSON")
KMS_KEY_ARN=""

if [[ -n "$KMS_IDS" ]]; then
  pick_resource "KMS Keys" "$KMS_IDS" "$KMS_LABELS"
  if [[ -n "$REPLY" ]]; then
    KMS_KEY_ARN="arn:aws:kms:${REGION}:${ACCT_ID}:key/${REPLY}"
    echo -e "  ${GRN}${OK}  Using KMS: ${KMS_KEY_ARN}${RST}"
  fi
fi
if [[ -z "$KMS_KEY_ARN" ]]; then
  echo -e "  ${YLW}  Creating new KMS symmetric key${RST}"
  if ! $DRY_RUN; then
    KMS_OUT=$(aws kms create-key --region "$REGION" \
      --description "Qlik OLH ${PREFIX}" --key-usage ENCRYPT_DECRYPT \
      --tags "TagKey=Name,TagValue=${PREFIX}-kms" "TagKey=Owner,TagValue=${INITIALS}" \
             "TagKey=Environment,TagValue=${ENV}" "TagKey=CreateDate,TagValue=${CREATE_DATE}" \
             "TagKey=Workload,TagValue=qlik-olh" \
      --output json)
    KEY_ID=$(py "import sys,json; print(json.load(sys.stdin)['KeyMetadata']['KeyId'])" <<< "$KMS_OUT")
    aws kms create-alias --alias-name "alias/${PREFIX}-kms" \
      --target-key-id "$KEY_ID" --region "$REGION" &>/dev/null
    KMS_KEY_ARN="arn:aws:kms:${REGION}:${ACCT_ID}:key/${KEY_ID}"
    echo -e "  ${GRN}${OK}  Created KMS: ${KMS_KEY_ARN}${RST}"
  else
    KMS_KEY_ARN="arn:aws:kms:${REGION}:${ACCT_ID}:key/DRYRUN"
    echo -e "  ${YLW}[DRY-RUN] Would create KMS key alias/${PREFIX}-kms${RST}"
  fi
fi

section "IAM Management Role"
# OLH needs two distinct roles and it matters which is which:
#
#   management role  - assumed by Qlik from outside your account, so its trust
#                      policy names the Qlik proxy principal and requires your
#                      tenant ExternalId. This is what the network integration
#                      connects through.
#   node role        - assumed by ec2.amazonaws.com, attached via the instance
#                      profile, and carries the S3/Kinesis/KMS/Glue grants that
#                      Terraform adds.
#
# Earlier versions of this wizard created only the EC2 role and reported it as
# mgmt_role_arn, which left QTC with nothing it could assume.

MGMT_ROLE_NAME="${PREFIX}-mgmt-role-iam"
NODE_ROLE_NAME="${PREFIX}-ec2-role-iam"

echo -e "  ${GRY}${ARW} aws iam get-role --role-name ${MGMT_ROLE_NAME}${RST}"
MGMT_TRUST=$(py "
import json
print(json.dumps({
  'Version': '2012-10-17',
  'Statement': [{
    'Effect': 'Allow',
    'Principal': {'AWS': '${QLIK_PROXY_ROLE_ARN}'},
    'Action': 'sts:AssumeRole',
    'Condition': {'StringEquals': {'sts:ExternalId': '${QTC_EXTERNAL_ID}'}}
  }]
}))
")

if aws iam get-role --role-name "$MGMT_ROLE_NAME" &>/dev/null; then
  echo -e "  ${GRN}${OK}  Management role exists: ${MGMT_ROLE_NAME}${RST}"
  if confirm "    Refresh its trust policy with the ExternalId you just entered?"; then
    if ! $DRY_RUN; then
      aws iam update-assume-role-policy --role-name "$MGMT_ROLE_NAME" \
        --policy-document "$MGMT_TRUST" &>/dev/null \
        && echo -e "  ${GRN}${OK}  Trust policy updated.${RST}" \
        || echo -e "  ${YLW}${WRN}  Could not update the trust policy.${RST}"
    else
      echo -e "  ${YLW}[DRY-RUN] Would update the trust policy.${RST}"
    fi
  fi
  MGMT_ROLE_ARN="arn:aws:iam::${ACCT_ID}:role/${MGMT_ROLE_NAME}"
else
  echo -e "  ${YLW}  Creating ${MGMT_ROLE_NAME}  (trusts ${QLIK_PROXY_ROLE_ARN})${RST}"
  if ! $DRY_RUN; then
    aws iam create-role --role-name "$MGMT_ROLE_NAME" \
      --description "Qlik Talend Cloud management role for ${PREFIX}" \
      --assume-role-policy-document "$MGMT_TRUST" \
      --tags "Key=Owner,Value=${INITIALS}" "Key=Environment,Value=${ENV}" \
             "Key=Workload,Value=qlik-olh" "Key=CreateDate,Value=${CREATE_DATE}" \
             "Key=ManagedBy,Value=script" &>/dev/null
    MGMT_ROLE_ARN="arn:aws:iam::${ACCT_ID}:role/${MGMT_ROLE_NAME}"
    echo -e "  ${GRN}${OK}  Created: ${MGMT_ROLE_ARN}${RST}"
    echo -e "  ${GRY}      Trust: ${QLIK_PROXY_ROLE_ARN} with sts:ExternalId${RST}"
  else
    MGMT_ROLE_ARN="arn:aws:iam::${ACCT_ID}:role/${MGMT_ROLE_NAME}-DRYRUN"
    echo -e "  ${YLW}[DRY-RUN] Would create IAM management role ${MGMT_ROLE_NAME}${RST}"
  fi
fi

# ── EC2 node role ────────────────────────────────────────────
section "EC2 Node Role"
NODE_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

if aws iam get-role --role-name "$NODE_ROLE_NAME" &>/dev/null; then
  echo -e "  ${GRN}${OK}  Node role exists: ${NODE_ROLE_NAME}${RST}"
  NODE_ROLE_ARN="arn:aws:iam::${ACCT_ID}:role/${NODE_ROLE_NAME}"
else
  echo -e "  ${YLW}  Creating ${NODE_ROLE_NAME}${RST}"
  if ! $DRY_RUN; then
    aws iam create-role --role-name "$NODE_ROLE_NAME" \
      --description "Qlik Open Lakehouse EC2 node role for ${PREFIX}" \
      --assume-role-policy-document "$NODE_TRUST" \
      --tags "Key=Owner,Value=${INITIALS}" "Key=Environment,Value=${ENV}" \
             "Key=Workload,Value=qlik-olh" "Key=CreateDate,Value=${CREATE_DATE}" \
             "Key=ManagedBy,Value=script" &>/dev/null
    echo -e "  ${GRY}${ARW} Attaching AmazonSSMManagedInstanceCore policy${RST}"
    aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
      --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" &>/dev/null
    NODE_ROLE_ARN="arn:aws:iam::${ACCT_ID}:role/${NODE_ROLE_NAME}"
    echo -e "  ${GRN}${OK}  Created: ${NODE_ROLE_ARN}  (SSM Core attached)${RST}"
    echo -e "  ${GRY}      Terraform adds the S3/Kinesis/KMS/Glue data-plane policy.${RST}"
  else
    NODE_ROLE_ARN="arn:aws:iam::${ACCT_ID}:role/${NODE_ROLE_NAME}-DRYRUN"
    echo -e "  ${YLW}[DRY-RUN] Would create IAM node role ${NODE_ROLE_NAME}${RST}"
  fi
fi

# ── Instance Profile ─────────────────────────────────────────
section "EC2 Instance Profile"
PROFILE_NAME="${PREFIX}-instance-profile"
echo -e "  ${GRY}${ARW} aws iam get-instance-profile --instance-profile-name ${PROFILE_NAME}${RST}"

if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" &>/dev/null; then
  echo -e "  ${GRN}${OK}  Instance profile exists: ${PROFILE_NAME}${RST}"
  INSTANCE_PROFILE_ARN="arn:aws:iam::${ACCT_ID}:instance-profile/${PROFILE_NAME}"
  # Make sure the node role really is the one inside it.
  PROF_ROLE=$(aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
    --query "InstanceProfile.Roles[0].RoleName" --output text 2>/dev/null || echo "")
  if [[ "$PROF_ROLE" != "$NODE_ROLE_NAME" && "$PROF_ROLE" != "None" && -n "$PROF_ROLE" ]]; then
    echo -e "  ${YLW}${WRN}  It currently holds role '${PROF_ROLE}', not ${NODE_ROLE_NAME}.${RST}"
  elif [[ -z "$PROF_ROLE" || "$PROF_ROLE" == "None" ]]; then
    echo -e "  ${YLW}${WRN}  It holds no role - attaching ${NODE_ROLE_NAME}.${RST}"
    if ! $DRY_RUN; then
      aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" \
        --role-name "$NODE_ROLE_NAME" &>/dev/null || true
    fi
  fi
else
  echo -e "  ${YLW}  Creating ${PROFILE_NAME}${RST}"
  if ! $DRY_RUN; then
    aws iam create-instance-profile \
      --instance-profile-name "$PROFILE_NAME" \
      --tags "Key=Owner,Value=${INITIALS}" "Key=Environment,Value=${ENV}" \
             "Key=CreateDate,Value=${CREATE_DATE}" &>/dev/null
    aws iam add-role-to-instance-profile \
      --instance-profile-name "$PROFILE_NAME" \
      --role-name "$NODE_ROLE_NAME" &>/dev/null
    INSTANCE_PROFILE_ARN="arn:aws:iam::${ACCT_ID}:instance-profile/${PROFILE_NAME}"
    echo -e "  ${GRN}${OK}  Created: ${INSTANCE_PROFILE_ARN}  (role ${NODE_ROLE_NAME})${RST}"
  else
    INSTANCE_PROFILE_ARN="arn:aws:iam::${ACCT_ID}:instance-profile/${PROFILE_NAME}-DRYRUN"
    echo -e "  ${YLW}[DRY-RUN] Would create instance profile${RST}"
  fi
fi

################################################################
#  GROUP 4 – Storage & Streaming (S3 → Kinesis)
################################################################
header "Group 4 of 5  –  Storage & Streaming"

create_or_use_bucket() {
  local bname="$1" label="$2"
  echo -e "  ${GRY}${ARW} aws s3api head-bucket --bucket ${bname}${RST}" >&2
  if aws s3api head-bucket --bucket "$bname" --region "$REGION" &>/dev/null; then
    echo -e "  ${GRN}${OK}  ${label} exists: ${bname}${RST}" >&2
    confirm "    Use existing '${bname}'?" && { echo "$bname"; return; }
  else
    echo -e "  ${YLW}${WRN}  ${label} not found.${RST}" >&2
  fi
  prompt_val "    Bucket name for ${label}" "$bname" \
    "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$" "Valid S3 bucket name."
  local bn="$REPLY"
  if ! $DRY_RUN; then
    local cb_out=""
    # us-east-1 rejects a LocationConstraint; every other region requires one.
    # if/else, not `[[ ]] && A || B`: a real failure of A must not fall through
    # to B and then be reported as success.
    if [[ "$REGION" == "us-east-1" ]]; then
      cb_out=$(aws s3api create-bucket --bucket "$bn" --region "$REGION" 2>&1) || {
        echo -e "  ${RED}${ERR}  Could not create ${bn}:${RST}" >&2
        echo -e "  ${GRY}      ${cb_out}${RST}" >&2
        exit 1; }
    else
      cb_out=$(aws s3api create-bucket --bucket "$bn" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=${REGION}" 2>&1) || {
        echo -e "  ${RED}${ERR}  Could not create ${bn}:${RST}" >&2
        echo -e "  ${GRY}      ${cb_out}${RST}" >&2
        exit 1; }
    fi
    # Default encryption with the OLH CMK, not the AWS-managed aws/s3 key:
    # Terraform grants the node role envelope encryption on this key, and
    # S3 Bucket Keys cut per-object KMS calls.
    local sse_cfg='{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
    if [[ -n "${KMS_KEY_ARN:-}" ]]; then
      sse_cfg="{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"${KMS_KEY_ARN}\"},\"BucketKeyEnabled\":true}]}"
    else
      echo -e "  ${YLW}${WRN}  No CMK ARN yet - ${bn} falls back to the AWS-managed S3 key.${RST}" >&2
    fi
    aws s3api put-bucket-encryption --bucket "$bn" \
      --server-side-encryption-configuration "$sse_cfg" &>/dev/null
    aws s3api put-public-access-block --bucket "$bn" \
      --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" &>/dev/null
    aws s3api put-bucket-tagging --bucket "$bn" --tagging \
      "TagSet=[{Key=Owner,Value=${INITIALS}},{Key=Environment,Value=${ENV}},{Key=Workload,Value=qlik-olh},{Key=Application,Value=open-lakehouse},{Key=CreateDate,Value=${CREATE_DATE}},{Key=ManagedBy,Value=script}]" &>/dev/null
    echo -e "  ${GRN}${OK}  Created: ${bn}  (KMS-encrypted, tags applied)${RST}" >&2
  else
    echo -e "  ${YLW}[DRY-RUN] Would create bucket: ${bn}${RST}" >&2
  fi
  echo "$bn"
}

section "S3 Buckets"
S3_ICEBERG=$(create_or_use_bucket "${PREFIX}-iceberg-s3"  "Iceberg bucket")
S3_LANDING=$(create_or_use_bucket "${PREFIX}-landing-s3"  "Landing bucket")
S3_CONFIG=$(create_or_use_bucket  "${PREFIX}-config-s3"   "Config bucket")
create_or_use_bucket "$TFSTATE_BUCKET" "TF State bucket" > /dev/null

# Terraform state benefits from versioning even though the lakehouse buckets
# do not need it. The GCS path does the same for its state bucket.
if ! $DRY_RUN; then
  aws s3api put-bucket-versioning --bucket "$TFSTATE_BUCKET" --region "$REGION" \
    --versioning-configuration Status=Enabled &>/dev/null \
    && echo -e "  ${GRN}${OK}  Versioning enabled on ${TFSTATE_BUCKET}.${RST}" \
    || echo -e "  ${YLW}${WRN}  Could not enable versioning on ${TFSTATE_BUCKET}.${RST}"
fi

section "Kinesis Stream"
KINESIS_NAME="${PREFIX}-stream-kinesis"
echo -e "  ${GRY}${ARW} aws kinesis describe-stream-summary --stream-name ${KINESIS_NAME}${RST}"
if aws kinesis describe-stream-summary --stream-name "$KINESIS_NAME" \
  --region "$REGION" &>/dev/null; then
  echo -e "  ${GRN}${OK}  Kinesis stream exists: ${KINESIS_NAME}${RST}"
  confirm "    Use existing stream?" || {
    prompt_val "New stream name" "${KINESIS_NAME}-2" "^[a-zA-Z0-9_.-]+$" "Valid stream name."
    KINESIS_NAME="$REPLY"
    dry_exec "aws kinesis create-stream --stream-name ${KINESIS_NAME} --shard-count 1 --region ${REGION}"
    echo -e "  ${GRN}${OK}  Created: ${KINESIS_NAME}${RST}"
  }
else
  echo -e "  ${YLW}${WRN}  Stream not found — creating.${RST}"
  if ! $DRY_RUN; then
    aws kinesis create-stream --stream-name "$KINESIS_NAME" \
      --shard-count 1 --region "$REGION"
    aws kinesis add-tags-to-stream --stream-name "$KINESIS_NAME" \
      --tags "Owner=${INITIALS},Environment=${ENV},Workload=qlik-olh,CreateDate=${CREATE_DATE}" \
      --region "$REGION" &>/dev/null
    echo -e "  ${GRN}${OK}  Created: ${KINESIS_NAME}${RST}"
  else
    echo -e "  ${YLW}[DRY-RUN] Would create Kinesis stream: ${KINESIS_NAME}${RST}"
  fi
fi

fi   # end of the per-cloud provisioning branch

################################################################
#  GROUP 5 - Tagging / Labelling Compliance Check
################################################################
header "Group 5 of 5  -  Tagging Compliance"

if [[ "$CLOUD" == "gcp" ]]; then
  TAG_WORD="labels"
  declare -A REQ_TAGS=( [owner]="$INITIALS" [environment]="$ENV" [workload]="qlik-olh" [application]="open-lakehouse" [createdate]="$CREATE_DATE" [managedby]="script" )
else
  TAG_WORD="tags"
  declare -A REQ_TAGS=( [Owner]="$INITIALS" [Environment]="$ENV" [Workload]="qlik-olh" [Application]="open-lakehouse" [CreateDate]="$CREATE_DATE" [ManagedBy]="script" )
fi

ALL_COMPLIANT=true
echo -e "  ${WHT}Required ${TAG_WORD} applied to all resources:${RST}\n"
printf "  ${CYN}%-20s %-30s %s${RST}\n" "Key" "Value" "Status"
echo "  $SEP"
for k in "${!REQ_TAGS[@]}"; do
  v="${REQ_TAGS[$k]}"
  if [[ -n "$v" ]]; then
    printf "  %-20s %-30s ${GRN}${OK} Compliant${RST}\n" "$k" "$v"
  else
    printf "  %-20s %-30s ${RED}${ERR} Missing value${RST}\n" "$k" "(empty)"
    ALL_COMPLIANT=false
  fi
done
echo ""
$ALL_COMPLIANT && echo -e "  ${GRN}${OK}  All required ${TAG_WORD} are compliant.${RST}" || \
  echo -e "  ${RED}${ERR}  Compliance failed. Fix before deploying.${RST}"

################################################################
#  REVIEW - Pre-Deploy Summary
################################################################
header "Review - Deployment Summary"

echo -e "  ${WHT}Please review the following configuration before proceeding:${RST}"
echo ""
printf "  ${CYN}%-28s %s${RST}\n" "Setting" "Value"
echo "  $SEP"
printf "  %-28s %s\n" "Target cloud" "$CLOUD_LABEL"
printf "  %-28s %s\n" "Owner Initials" "$INITIALS"
printf "  %-28s %s\n" "Workload" "$WORKLOAD"
printf "  %-28s %s\n" "Environment" "$ENV"
printf "  %-28s %s\n" "Region" "$REGION"
printf "  %-28s %s\n" "Prefix" "$PREFIX"

if [[ "$CLOUD" == "gcp" ]]; then
  printf "  %-28s %s\n" "Project ID" "$GCP_PROJECT_ID"
  printf "  %-28s %s\n" "Project number" "$GCP_PROJECT_NUMBER"
  printf "  %-28s %s\n" "Authenticated as" "$CALLER"
  printf "  %-28s %s\n" "Zones" "${GCP_ZONES[*]}"
  echo "  $SEP"
  printf "  %-28s %s\n" "VPC network" "$NETWORK_NAME"
  printf "  %-28s %s\n" "Subnetwork" "$SUBNETWORK_NAME"
  printf "  %-28s %s\n" "Subnetwork CIDR" "$SUBNETWORK_CIDR"
  printf "  %-28s %s\n" "Firewall rule" "$FIREWALL_RULE"
  printf "  %-28s %s\n" "Cloud NAT" "$NAT_NAME"
  echo "  $SEP"
  printf "  %-28s %s\n" "KMS key" "$KMS_KEY_ID"
  printf "  %-28s %s\n" "Management SA" "$MGMT_SA"
  printf "  %-28s %s\n" "Node SA" "$NODE_SA"
  printf "  %-28s %s\n" "QTC auth method" "$QTC_AUTH_METHOD"
  echo "  $SEP"
  printf "  %-28s %s\n" "GCS table storage" "$GCS_TABLE"
  printf "  %-28s %s\n" "GCS landing" "$GCS_LANDING"
  printf "  %-28s %s\n" "GCS config" "$GCS_CONFIG"
  printf "  %-28s %s\n" "TF state bucket" "$TFSTATE_BUCKET"
  printf "  %-28s %s\n" "Streaming" "none (Private Preview: CDC + SaaS only)"
else
  SUBNET_SUMMARY=""
  for pair in "${SUBNET_AZ_PAIRS[@]}"; do
    sub="${pair%%|*}"; az="${pair##*|}"
    SUBNET_SUMMARY+="    ${sub}  (${az})"$'\n'
  done
  printf "  %-28s %s\n" "AWS Account" "$ACCT_ID"
  printf "  %-28s %s\n" "Caller ARN" "$CALLER"
  echo "  $SEP"
  printf "  %-28s %s\n" "VPC ID" "$VPC_ID"
  printf "  %-28s %s\n" "VPC CIDR" "$VPC_CIDR"
  printf "  %-28s %s\n" "Security Group" "$SG_ID"
  printf "  %-28s %s\n" "S3 gateway endpoint" "${S3_VPCE_ID:-(Terraform will create)}"
  echo -e "  Subnets:"
  echo -n "$SUBNET_SUMMARY"
  echo "  $SEP"
  printf "  %-28s %s\n" "KMS Key ARN" "$KMS_KEY_ARN"
  printf "  %-28s %s\n" "Management Role ARN" "$MGMT_ROLE_ARN"
  printf "  %-28s %s\n" "Node Role ARN" "$NODE_ROLE_ARN"
  printf "  %-28s %s\n" "Instance Profile ARN" "$INSTANCE_PROFILE_ARN"
  printf "  %-28s %s\n" "Qlik proxy principal" "$QLIK_PROXY_ROLE_ARN"
  echo "  $SEP"
  printf "  %-28s %s\n" "S3 Iceberg" "${S3_ICEBERG}"
  printf "  %-28s %s\n" "S3 Landing" "${S3_LANDING}"
  printf "  %-28s %s\n" "S3 Config" "${S3_CONFIG}"
  printf "  %-28s %s\n" "TF State Bucket" "${TFSTATE_BUCKET}"
  printf "  %-28s %s\n" "Kinesis Stream" "${KINESIS_NAME}  (1 shard)"
fi
echo "  $SEP"
echo ""
MODE_DESC="LIVE"
$DRY_RUN && MODE_DESC="${YLW}DRY-RUN (no resources will be created)${RST}"
echo -e "  ${WHT}Mode: ${MODE_DESC}${RST}"
echo ""

if ! confirm "  Proceed to generate output files and run Terraform?"; then
  echo -e "  ${RED}Aborted.${RST}"; exit 0
fi

################################################################
#  OUTPUT FILES
################################################################
header "Writing Output Files"

# SCRIPT_DIR / TF_PATH / TFVARS are resolved at the top of the script.
mkdir -p "$TF_PATH"

if [[ "$CLOUD" == "gcp" ]]; then
  ZONES_HCL=""
  for z in "${GCP_ZONES[@]}"; do
    ZONES_HCL+="${ZONES_HCL:+, }\"${z}\""
  done

  cat > "$TFVARS" <<EOF
# Generated by qlik_deploy_olh.sh
# $(date "+%Y-%m-%d %H:%M:%S")
# Cloud: Google Cloud   Mode: $( $DRY_RUN && echo "DRY-RUN" || echo "LIVE")
#
# Contains your QTC tenant ID. Keep it out of source control.

initials                   = "${INITIALS}"
workload                   = "${WORKLOAD}"
env                        = "${ENV}"

gcp_project_id             = "${GCP_PROJECT_ID}"
gcp_project_number         = "${GCP_PROJECT_NUMBER}"
gcp_region                 = "${GCP_REGION}"
gcp_zones                  = [${ZONES_HCL}]
tfstate_bucket             = "${TFSTATE_BUCKET}"

network_name               = "${NETWORK_NAME}"
subnetwork_name            = "${SUBNETWORK_NAME}"
subnetwork_cidr            = "${SUBNETWORK_CIDR}"
firewall_rule_name         = "${FIREWALL_RULE}"

kms_key_id                 = "${KMS_KEY_ID}"
mgmt_service_account_email = "${MGMT_SA}"
node_service_account_email = "${NODE_SA}"

qtc_auth_method            = "${QTC_AUTH_METHOD}"
qtc_oidc_issuer_uri        = "${QTC_OIDC_ISSUER}"
qtc_tenant_id              = "${QTC_TENANT_ID}"

gcs_table_bucket           = "${GCS_TABLE}"
gcs_landing_bucket         = "${GCS_LANDING}"
gcs_config_bucket          = "${GCS_CONFIG}"

# Labels
tag_owner      = "${INITIALS}"
tag_env        = "${ENV}"
tag_workload   = "qlik-olh"
tag_createdate = "${CREATE_DATE}"
EOF
else
  SUBNET_IDS_HCL=""
  for pair in "${SUBNET_AZ_PAIRS[@]}"; do
    sub="${pair%%|*}"
    SUBNET_IDS_HCL+="${SUBNET_IDS_HCL:+, }\"${sub}\""
  done

  cat > "$TFVARS" <<EOF
# Generated by qlik_deploy_olh.sh
# $(date "+%Y-%m-%d %H:%M:%S")
# Cloud: AWS   Mode: $( $DRY_RUN && echo "DRY-RUN" || echo "LIVE")
#
# Contains your QTC ExternalId. Keep it out of source control.

initials               = "${INITIALS}"
workload               = "${WORKLOAD}"
env                    = "${ENV}"
aws_region             = "${REGION}"
aws_account_id         = "${ACCT_ID}"
tfstate_bucket         = "${TFSTATE_BUCKET}"

vpc_id                 = "${VPC_ID}"
vpc_cidr               = "${VPC_CIDR}"
subnet_ids             = [${SUBNET_IDS_HCL}]
security_group_id      = "${SG_ID}"
s3_gateway_endpoint_id = "${S3_VPCE_ID}"

kms_key_arn            = "${KMS_KEY_ARN}"
mgmt_role_arn          = "${MGMT_ROLE_ARN}"
node_role_arn          = "${NODE_ROLE_ARN}"
instance_profile_arn   = "${INSTANCE_PROFILE_ARN}"
qlik_proxy_role_arn    = "${QLIK_PROXY_ROLE_ARN}"
qtc_external_id        = "${QTC_EXTERNAL_ID}"

s3_bucket_name         = "${S3_ICEBERG}"
s3_landing_bucket      = "${S3_LANDING}"
s3_config_bucket       = "${S3_CONFIG}"
kinesis_stream_name    = "${KINESIS_NAME}"
kinesis_shards         = 1

# Tags
tag_owner      = "${INITIALS}"
tag_env        = "${ENV}"
tag_workload   = "qlik-olh"
tag_createdate = "${CREATE_DATE}"
EOF
fi
echo -e "  ${GRN}${OK}  ${TFVARS}${RST}"

# ── QTC reference file ───────────────────────────────────────
QTC_FILE="${SCRIPT_DIR}/qlik-network-integration.txt"
if [[ "$CLOUD" == "gcp" ]]; then
  cat > "$QTC_FILE" <<EOF
$(printf '=%.0s' {1..64})
  Qlik Open Lakehouse - QTC Network Integration Reference
  Cloud      : Google Cloud  (Private Preview)
  Generated  : $(date "+%Y-%m-%d %H:%M:%S")
  Prefix     : ${PREFIX}
  Mode       : $( $DRY_RUN && echo "DRY-RUN" || echo "LIVE")
$(printf '=%.0s' {1..64})

${SEP}
  ENTITY                         VALUE
${SEP}
  Project ID                   : ${GCP_PROJECT_ID}
  Project Number               : ${GCP_PROJECT_NUMBER}
  Region                       : ${GCP_REGION}
  Zones                        : ${GCP_ZONES[*]}
  VPC Network                  : ${NETWORK_NAME}
  Subnetwork                   : ${SUBNETWORK_NAME}
  Subnetwork CIDR              : ${SUBNETWORK_CIDR}
  Firewall Rule                : ${FIREWALL_RULE}
  Cloud NAT                    : ${NAT_NAME}
  Cloud KMS Key                : ${KMS_KEY_ID}
  Management Service Account   : ${MGMT_SA}
  Node Service Account         : ${NODE_SA}
  GCS Table Storage Bucket     : ${GCS_TABLE}
  GCS Landing Bucket           : ${GCS_LANDING}
  GCS Config Bucket            : ${GCS_CONFIG}
  QTC Auth Method              : ${QTC_AUTH_METHOD}
${SEP}

  APPLIED LABELS
${SEP}
  owner         : ${INITIALS}
  environment   : ${ENV}
  workload      : qlik-olh
  application   : open-lakehouse
  createdate    : ${CREATE_DATE}
  managedby     : script
${SEP}

  CREATED BY TERRAFORM
${SEP}
  BigLake Catalog  : ${INITIALS}_${WORKLOAD}_${ENV}_catalog
  BigLake Database : ${INITIALS}_${WORKLOAD}_${ENV}_db
  BigQuery Mirror  : ${INITIALS}_${WORKLOAD}_${ENV}_mirror
  Secret prefix    : ${INITIALS}-${WORKLOAD}-${ENV}
${SEP}

  PREVIEW NOTES
${SEP}
  * Private Preview opened 2 Sep 2026; GA planned Q4 2026.
  * Ingestion scope at launch: CDC and SaaS sources only.
    Streaming (Kafka / GCS) and Qlik Replicate sources arrive later.
  * Zero-copy mirroring to BigQuery is a Google Cloud only feature.
  * The QTC authentication model on GCP is not yet published. This run
    configured '${QTC_AUTH_METHOD}' - confirm it against your preview
    onboarding pack before treating it as final.
${SEP}
EOF
else
  SUBNET_BLOCK=""
  for pair in "${SUBNET_AZ_PAIRS[@]}"; do
    sub="${pair%%|*}"; az="${pair##*|}"
    SUBNET_BLOCK+="    Subnet: ${sub}   AZ: ${az}"$'\n'
  done
  cat > "$QTC_FILE" <<EOF
$(printf '=%.0s' {1..64})
  Qlik Open Lakehouse - QTC Network Integration Reference
  Cloud      : AWS
  Generated  : $(date "+%Y-%m-%d %H:%M:%S")
  Prefix     : ${PREFIX}
  Mode       : $( $DRY_RUN && echo "DRY-RUN" || echo "LIVE")
$(printf '=%.0s' {1..64})

${SEP}
  ENTITY                         VALUE
${SEP}
  AWS Account ID               : ${ACCT_ID}
  VPC ID                       : ${VPC_ID}
  CIDR Range of VPC            : ${VPC_CIDR}

  Subnet / Availability Zone pairs:
${SUBNET_BLOCK}
  Symmetric KMS Key ARN        : ${KMS_KEY_ARN}
  S3 Bucket Name               : ${S3_ICEBERG}
  Kinesis Stream Name          : ${KINESIS_NAME}
  Security Group ID            : ${SG_ID}
  S3 Gateway VPC Endpoint      : ${S3_VPCE_ID:-created by Terraform}
  Management Role ARN          : ${MGMT_ROLE_ARN}
  Node Role ARN                : ${NODE_ROLE_ARN}
  Instance Profile ARN         : ${INSTANCE_PROFILE_ARN}
${SEP}

  APPLIED TAGS
${SEP}
  Owner         : ${INITIALS}
  Environment   : ${ENV}
  Workload      : qlik-olh
  Application   : open-lakehouse
  CreateDate    : ${CREATE_DATE}
  ManagedBy     : script
${SEP}

  GENERATED RESOURCE NAMES
${SEP}
  S3 Iceberg    : ${S3_ICEBERG}
  S3 Landing    : ${S3_LANDING}
  S3 Config     : ${S3_CONFIG}
  Mgmt Role     : ${PREFIX}-mgmt-role-iam
  Node Role     : ${PREFIX}-ec2-role-iam
  Glue Database : ${INITIALS}_${WORKLOAD}_${ENV}_db_glue
  SSM Path      : /${INITIALS}/${WORKLOAD}/${ENV}
${SEP}
EOF
fi
echo -e "  ${GRN}${OK}  ${QTC_FILE}${RST}"

# ── HTML deployment report ───────────────────────────────────
RPT_FILE="${SCRIPT_DIR}/deploy-report.html"
if [[ "$CLOUD" == "gcp" ]]; then
  RPT_NET_ROWS="<div class=\"k\">VPC Network</div><div class=\"v\">${NETWORK_NAME}</div>
  <div class=\"k\">Subnetwork</div><div class=\"v\">${SUBNETWORK_NAME}</div>
  <div class=\"k\">Subnetwork CIDR</div><div class=\"v\">${SUBNETWORK_CIDR}</div>
  <div class=\"k\">Firewall Rule</div><div class=\"v\">${FIREWALL_RULE}</div>
  <div class=\"k\">Cloud NAT</div><div class=\"v\">${NAT_NAME}</div>
  <div class=\"k\">Zones</div><div class=\"v\">${GCP_ZONES[*]}</div>"
  RPT_SEC_ROWS="<div class=\"k\">Cloud KMS Key</div><div class=\"v\">${KMS_KEY_ID}</div>
  <div class=\"k\">Management SA</div><div class=\"v\">${MGMT_SA}</div>
  <div class=\"k\">Node SA</div><div class=\"v\">${NODE_SA}</div>
  <div class=\"k\">QTC Auth Method</div><div class=\"v\">${QTC_AUTH_METHOD}</div>"
  RPT_STO_ROWS="<div class=\"k\">GCS Table Storage</div><div class=\"v\">${GCS_TABLE}</div>
  <div class=\"k\">GCS Landing</div><div class=\"v\">${GCS_LANDING}</div>
  <div class=\"k\">GCS Config</div><div class=\"v\">${GCS_CONFIG}</div>
  <div class=\"k\">Streaming</div><div class=\"v\">none &mdash; Private Preview covers CDC and SaaS sources</div>"
  RPT_GEN_ROWS="<div class=\"k\">BigLake Catalog</div><div class=\"v\">${INITIALS}_${WORKLOAD}_${ENV}_catalog</div>
  <div class=\"k\">BigLake Database</div><div class=\"v\">${INITIALS}_${WORKLOAD}_${ENV}_db</div>
  <div class=\"k\">BigQuery Mirror</div><div class=\"v\">${INITIALS}_${WORKLOAD}_${ENV}_mirror</div>
  <div class=\"k\">TF State Bucket</div><div class=\"v\">${TFSTATE_BUCKET}</div>"
  RPT_TAGS="owner|environment|workload|application|createdate|managedby"
  RPT_EXTRA_CHIP='<span class="chip warn">Google Cloud &mdash; Private Preview</span>'
  RPT_SUB="Prefix: ${PREFIX} &nbsp;|&nbsp; Project: ${GCP_PROJECT_ID} &nbsp;|&nbsp; Region: ${GCP_REGION}"
else
  SUBNET_HTML=""
  for pair in "${SUBNET_AZ_PAIRS[@]}"; do
    sub="${pair%%|*}"; az="${pair##*|}"
    SUBNET_HTML+="${sub} (${az})<br/>"
  done
  RPT_NET_ROWS="<div class=\"k\">VPC ID</div><div class=\"v\">${VPC_ID}</div>
  <div class=\"k\">VPC CIDR</div><div class=\"v\">${VPC_CIDR}</div>
  <div class=\"k\">Security Group</div><div class=\"v\">${SG_ID}</div>
  <div class=\"k\">S3 Gateway Endpoint</div><div class=\"v\">${S3_VPCE_ID:-created by Terraform}</div>
  <div class=\"k\">Subnets / AZs</div><div class=\"v\">${SUBNET_HTML}</div>"
  RPT_SEC_ROWS="<div class=\"k\">KMS Key ARN</div><div class=\"v\">${KMS_KEY_ARN}</div>
  <div class=\"k\">Management Role</div><div class=\"v\">${MGMT_ROLE_ARN}</div>
  <div class=\"k\">Node Role</div><div class=\"v\">${NODE_ROLE_ARN}</div>
  <div class=\"k\">Instance Profile</div><div class=\"v\">${INSTANCE_PROFILE_ARN}</div>
  <div class=\"k\">Qlik Proxy Principal</div><div class=\"v\">${QLIK_PROXY_ROLE_ARN}</div>"
  RPT_STO_ROWS="<div class=\"k\">S3 Iceberg</div><div class=\"v\">${S3_ICEBERG}</div>
  <div class=\"k\">S3 Landing</div><div class=\"v\">${S3_LANDING}</div>
  <div class=\"k\">S3 Config</div><div class=\"v\">${S3_CONFIG}</div>
  <div class=\"k\">Kinesis Stream</div><div class=\"v\">${KINESIS_NAME} (1 shard)</div>"
  RPT_GEN_ROWS="<div class=\"k\">Glue Database</div><div class=\"v\">${INITIALS}_${WORKLOAD}_${ENV}_db_glue</div>
  <div class=\"k\">SSM Path</div><div class=\"v\">/${INITIALS}/${WORKLOAD}/${ENV}</div>
  <div class=\"k\">TF State Bucket</div><div class=\"v\">${TFSTATE_BUCKET}</div>"
  RPT_TAGS="Owner|Environment|Workload|Application|CreateDate|ManagedBy"
  RPT_EXTRA_CHIP=''
  RPT_SUB="Prefix: ${PREFIX} &nbsp;|&nbsp; Account: ${ACCT_ID} &nbsp;|&nbsp; Region: ${REGION}"
fi

IFS='|' read -r T1 T2 T3 T4 T5 T6 <<< "$RPT_TAGS"

cat > "$RPT_FILE" <<EOF
<!DOCTYPE html><html><head><meta charset="UTF-8">
<title>Qlik OLH Deploy Report - ${PREFIX}</title>
<style>
body{font-family:Segoe UI,sans-serif;background:#f5f7f5;color:#1f2328;padding:24px;max-width:900px;margin:auto}
h1{color:#fff;background:#194268;padding:14px 20px;border-radius:8px;margin-bottom:16px;font-size:18px}
h1 small{font-size:12px;opacity:.8;display:block;margin-top:4px}
.section{background:#fff;border:1px solid #c8d6c8;border-radius:7px;margin-bottom:12px;overflow:hidden}
.section h2{background:#e8f5ed;padding:8px 16px;font-size:13px;color:#009845;margin:0;border-bottom:1px solid #c8d6c8}
.grid{display:grid;grid-template-columns:200px 1fr;font-size:12px}
.k{padding:5px 16px;color:#54565a;background:#fafbfa;border-bottom:1px solid #e8f5ed}
.v{padding:5px 16px;font-family:monospace;border-bottom:1px solid #e8f5ed;word-break:break-all}
.tags{display:flex;flex-wrap:wrap;gap:5px;padding:10px 16px}
.tag{background:#e8f5ed;color:#156037;border:1px solid #009845;padding:2px 9px;border-radius:10px;font-size:11px}
.chips{display:flex;gap:8px;padding:10px 16px;flex-wrap:wrap}
.chip{padding:3px 12px;border-radius:10px;font-size:12px;font-weight:600}
.ok{background:#dafbe1;color:#116329}.warn{background:#fff8c5;color:#9a6700}
</style></head><body>
<h1>Qlik Open Lakehouse - Deployment Report<small>${CLOUD_LABEL} &nbsp;|&nbsp; ${RPT_SUB} &nbsp;|&nbsp; $(date)</small></h1>
<div class="section"><h2>Status</h2><div class="chips">
  <span class="chip ok">Resources Provisioned</span>
  $( $ALL_COMPLIANT && echo '<span class="chip ok">Tagging Compliant</span>' || echo '<span class="chip warn">Tagging Non-Compliant</span>')
  ${RPT_EXTRA_CHIP}
  $( $DRY_RUN && echo '<span class="chip warn">Dry-Run Mode</span>' || echo '<span class="chip ok">Live Mode</span>')
</div></div>
<div class="section"><h2>Network</h2><div class="grid">
  ${RPT_NET_ROWS}
</div></div>
<div class="section"><h2>Security &amp; Encryption</h2><div class="grid">
  ${RPT_SEC_ROWS}
</div></div>
<div class="section"><h2>Storage &amp; Streaming</h2><div class="grid">
  ${RPT_STO_ROWS}
</div></div>
<div class="section"><h2>Applied $( [[ "$CLOUD" == "gcp" ]] && echo "Labels" || echo "Tags")</h2><div class="tags">
  <span class="tag">${T1}: ${INITIALS}</span>
  <span class="tag">${T2}: ${ENV}</span>
  <span class="tag">${T3}: qlik-olh</span>
  <span class="tag">${T4}: open-lakehouse</span>
  <span class="tag">${T5}: ${CREATE_DATE}</span>
  <span class="tag">${T6}: script</span>
</div></div>
<div class="section"><h2>Created by Terraform</h2><div class="grid">
  ${RPT_GEN_ROWS}
</div></div>
</body></html>
EOF
echo -e "  ${GRN}${OK}  ${RPT_FILE}${RST}"

################################################################
#  TERRAFORM
################################################################
if ! $DRY_RUN && [[ "$TERRAFORM_OK" == "true" ]]; then
  header "Terraform Init -> Plan -> Apply  (${TF_DIR})"

  echo -e "  ${GRY}${ARW} terraform -chdir=${TF_DIR} init${RST}"
  if [[ "$CLOUD" == "gcp" ]]; then
    terraform -chdir="$TF_PATH" init -reconfigure \
      -backend-config="bucket=${TFSTATE_BUCKET}" \
      -backend-config="prefix=qlik-lakehouse" || abort_on_fail $? "terraform init failed."
  else
    terraform -chdir="$TF_PATH" init -reconfigure \
      -backend-config="bucket=${TFSTATE_BUCKET}" \
      -backend-config="key=qlik-lakehouse/terraform.tfstate" \
      -backend-config="region=${REGION}" || abort_on_fail $? "terraform init failed."
  fi
  echo -e "  ${GRN}${OK}  Init complete.${RST}\n"

  echo -e "  ${GRY}${ARW} terraform -chdir=${TF_DIR} plan${RST}"
  terraform -chdir="$TF_PATH" plan -var-file="terraform.tfvars" -out="tfplan" \
    || abort_on_fail $? "terraform plan failed."
  echo -e "  ${GRN}${OK}  Plan saved to ${TF_DIR}/tfplan.${RST}\n"

  if confirm "  Apply the plan now?"; then
    terraform -chdir="$TF_PATH" apply "tfplan" || abort_on_fail $? "terraform apply failed."
    echo -e "  ${GRN}${OK}  Apply complete!${RST}"
    echo ""
    echo -e "  ${CYN}QTC integration values:${RST}"
    terraform -chdir="$TF_PATH" output qtc_summary || true
  fi
elif $DRY_RUN; then
  echo -e "\n  ${YLW}[DRY-RUN] Skipping terraform init/plan/apply.${RST}"
else
  echo -e "\n  ${YLW}${WRN}  Terraform not available - skipping init/plan/apply.${RST}"
fi

################################################################
#  AUTO-OPEN QTC REFERENCE FILE
################################################################
header "Complete"
echo -e "  ${GRN}${OK}  Output files:${RST}"
echo -e "  ${GRY}    - ${TF_DIR}/terraform.tfvars${RST}"
echo -e "  ${GRY}    - qlik-network-integration.txt${RST}"
echo -e "  ${GRY}    - deploy-report.html${RST}"
echo ""
echo -e "  ${CYN}Opening qlik-network-integration.txt ...${RST}"
if   command -v xdg-open &>/dev/null; then xdg-open "$QTC_FILE" &
elif command -v open     &>/dev/null; then open      "$QTC_FILE"
else cat "$QTC_FILE"; fi

echo ""
echo -e "  ${WHT}Next steps:${RST}"
if [[ "$CLOUD" == "gcp" ]]; then
  echo -e "  ${GRY}    1. Copy values from qlik-network-integration.txt into QTC${RST}"
  echo -e "  ${GRY}    2. Create the Network Integration in Qlik Talend Cloud${RST}"
  echo -e "  ${GRY}    3. Create the Lakehouse Cluster (Spot VM MIG across ${GCP_ZONES[*]})${RST}"
  echo -e "  ${GRY}    4. Connect the Google Lakehouse Runtime Catalog${RST}"
  echo -e "  ${GRY}    5. Optional: enable zero-copy mirroring into BigQuery${RST}"
  echo ""
  echo -e "  ${YLW}  Reminder: your tenant must be enrolled in the Google Cloud Private${RST}"
  echo -e "  ${YLW}  Preview before a lakehouse cluster can be created.${RST}"
else
  echo -e "  ${GRY}    1. Copy values from qlik-network-integration.txt into QTC${RST}"
  echo -e "  ${GRY}    2. Create Network Integration in Qlik Talend Cloud${RST}"
  echo -e "  ${GRY}    3. Configure Lakehouse Cluster + Glue catalog connection${RST}"
fi
echo ""
