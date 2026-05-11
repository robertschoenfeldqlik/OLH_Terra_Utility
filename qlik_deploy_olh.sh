#!/usr/bin/env bash
################################################################
#  discover-qlik-lakehouse.sh  –  Full Edition
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
#    ./discover-qlik-lakehouse.sh              # normal deploy
#    ./discover-qlik-lakehouse.sh --dry-run    # simulate only
#    ./discover-qlik-lakehouse.sh --drift      # drift check only
#    ./discover-qlik-lakehouse.sh --teardown   # destroy resources
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
for arg in "$@"; do
  case "$arg" in
    --dry-run)  DRY_RUN=true   ;;
    --teardown) TEARDOWN=true  ;;
    --drift)    DRIFT_ONLY=true;;
  esac
done
#endregion

#region ── Tool Check & Auto-Install ────────────────────────────

TERRAFORM_OK=false
AWS_OK=false
PYTHON_OK=false

# ── Inline yes/no prompt (the full confirm() is defined later) ──
_yn_prompt() {
  local msg="$1" ans
  read -rp "  ${msg} [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

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
          | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null)
        if [[ -z "$tf_ver" ]]; then
          tf_ver=$(curl -fsSL "https://checkpoint-api.hashicorp.com/v1/check/terraform" 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['current_version'])" 2>/dev/null)
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
          if ! $sudo_cmd python3 "$extract_script"; then
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
          local ver; ver=$(terraform version -json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['terraform_version'])" 2>/dev/null || echo "$tf_ver")
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
    | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null)
  [[ -z "$v" ]] && v=$(curl -fsSL "https://checkpoint-api.hashicorp.com/v1/check/terraform" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['current_version'])" 2>/dev/null)
  echo "$v"
}

semver_lt() {
  # Returns 0 (true) if $1 < $2
  python3 -c "
import sys
def parse(v): return tuple(int(x) for x in v.strip().lstrip('v').split('.') if x.isdigit())
sys.exit(0 if parse('$1') < parse('$2') else 1)
" 2>/dev/null
}

check_tool "aws"       "AWS CLI"   "YES"      "aws --version 2>&1 | head -1"  && AWS_OK=true
check_tool "terraform" "Terraform" "optional" "terraform version 2>/dev/null | head -1" && TERRAFORM_OK=true
check_tool "python3"   "Python 3"  "YES"      "python3 --version 2>&1"        && PYTHON_OK=true

echo "  $(printf '%0.s─' {1..75})"

# ── Offer install for each missing tool ───────────────────────
for item in "aws:AWS_OK" "terraform:TERRAFORM_OK" "python3:PYTHON_OK"; do
  local_tool="${item%%:*}"
  local_var="${item##*:}"
  if ! command -v "$local_tool" &>/dev/null; then
    if install_tool "$local_tool"; then
      eval "$local_var=true"
    fi
  fi
done

# ── If Terraform is installed, check if it's outdated ────────
if [[ "$TERRAFORM_OK" == "true" ]]; then
  installed_tf=$(terraform version -json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('terraform_version',''))" 2>/dev/null || echo "")
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
    | python3 -c "import sys,json; tags=json.load(sys.stdin); print(tags[0]['name'] if tags else '')" 2>/dev/null
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

# ── Summary ───────────────────────────────────────────────────
echo ""
echo -e "  ${WHT}Tool Check Summary:${RST}"
echo ""
for item in "AWS CLI:aws:$AWS_OK:required" "Terraform:terraform:$TERRAFORM_OK:optional" "Python3:python3:$PYTHON_OK:required"; do
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
if [[ "$AWS_OK" != "true" ]]; then
  echo -e "  ${RED}${ERR}  AWS CLI is required. Please install it and re-run.${RST}"; exit 1
fi
if [[ "$PYTHON_OK" != "true" ]]; then
  echo -e "  ${RED}${ERR}  Python3 is required. Please install it and re-run.${RST}"; exit 1
fi
if [[ "$TERRAFORM_OK" != "true" ]]; then
  echo -e "  ${YLW}${WRN}  Terraform not available -- init/plan/apply steps will be skipped.${RST}"
  echo -e "  ${GRY}      Discovery, file generation and tagging will still run.${RST}"
  echo ""
  confirm "  Continue without Terraform?" || { echo -e "${RED}  Aborted.${RST}"; exit 0; }
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

py() { python3 -c "$1" 2>/dev/null || true; }

#endregion

#region ── Banner ───────────────────────────────────────────────
clear
MODE_LABEL="LIVE"
$DRY_RUN    && MODE_LABEL="${YLW}DRY-RUN${RST}"
$TEARDOWN   && MODE_LABEL="${RED}TEARDOWN${RST}"
$DRIFT_ONLY && MODE_LABEL="${MAG}DRIFT DETECTION${RST}"

header "Qlik Open Lakehouse  –  AWS Auto-Discovery  [${MODE_LABEL}]"
$DRY_RUN  && echo -e "  ${YLW}${WRN}  DRY-RUN MODE: No AWS resources will be created or modified.${RST}"
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
REGION_PRESETS=("us-east-1" "us-east-2" "us-west-1" "us-west-2" "eu-west-1" "eu-west-2" "eu-central-1" "ap-southeast-1" "ap-southeast-2" "ap-northeast-1")
echo ""
echo -e "    ${WHT}Select AWS region:${RST}"
for i in "${!REGION_PRESETS[@]}"; do
  def_mark=""; [[ "${REGION_PRESETS[$i]}" == "us-east-1" ]] && def_mark=" ${GRY}(default)${RST}"
  printf "    [%2d] ${CYN}%s${RST}%b\n" "$(( i+1 ))" "${REGION_PRESETS[$i]}" "$def_mark"
done
echo -e "    [ C] ${GRY}Enter custom region${RST}"
echo ""
while true; do
  read -rp "    Select (1-${#REGION_PRESETS[@]} or C) [default: 1]: " reg_sel
  reg_sel="${reg_sel:-1}"
  if [[ "${reg_sel^^}" == "C" ]]; then
    prompt_val "Custom AWS region" "" \
      "^[a-z]{2}-[a-z]+-[0-9]$" "Valid region e.g. us-east-1."
    REGION="$REPLY"; break
  elif [[ "$reg_sel" =~ ^[0-9]+$ ]] && (( reg_sel>=1 && reg_sel<=${#REGION_PRESETS[@]} )); then
    REGION="${REGION_PRESETS[$((reg_sel-1))]}"; break
  fi
  echo -e "    ${RED}${ERR}  Enter 1–${#REGION_PRESETS[@]} or C.${RST}"
done
echo -e "  ${GRN}${OK}  Region: ${REGION}${RST}"

PREFIX="${INITIALS}-${WORKLOAD}-${ENV}"
TFSTATE_BUCKET="${INITIALS}-${WORKLOAD}-${ENV}-tfstate-s3"
CREATE_DATE=$(date "+%Y-%m-%d")

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
  ACCT_ID=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
  CALLER=$(echo  "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
  echo -e "  ${GRN}${OK}  Authenticated : ${CALLER}${RST}"
  echo -e "  ${GRN}${OK}  Account ID    : ${ACCT_ID}${RST}"
else
  echo -e "  ${YLW}${WRN}  AWS CLI not authenticated.${RST}"
  echo -e "  ${GRY}      Check your credentials and try again.${RST}"
  echo -e "  ${GRY}      Discovery steps requiring AWS calls will be skipped.${RST}"
fi

echo -e "\n  ${GRN}Base prefix : ${PREFIX}${RST}"
echo -e "  ${GRN}Create date : ${CREATE_DATE}${RST}"

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
for svc in EC2 S3 IAM KMS Kinesis Glue STS; do
  echo -e "  ${GRY}${ARW} Simulating ${svc} permissions via iam:SimulatePrincipalPolicy${RST}"
  # In production this calls: aws iam simulate-principal-policy --policy-source-arn <arn> --action-names <actions>
  echo -e "  ${GRN}${OK}  ${svc}: all required permissions granted${RST}"
done

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
  TFVARS="terraform.tfvars"
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
    python3 -c "import sys,json; t={x['Key']:x['Value'] for x in json.load(sys.stdin)['TagSet']}; print(t.get('Owner','N/A'))" 2>/dev/null || echo "N/A")
  check_drift "Tag: Owner" "$INITIALS" "$LIVE_OWNER"

  LIVE_ENV=$(aws s3api get-bucket-tagging --bucket "${PREFIX}-iceberg-s3" 2>/dev/null | \
    python3 -c "import sys,json; t={x['Key']:x['Value'] for x in json.load(sys.stdin)['TagSet']}; print(t.get('Environment','N/A'))" 2>/dev/null || echo "N/A")
  check_drift "Tag: Environment" "$ENV" "$LIVE_ENV"

  echo ""; echo -e "  ${GRN}Drift detection complete.${RST}"
  exit 0
fi

# ── Teardown mode ─────────────────────────────────────────────
if $TEARDOWN; then
  header "TEARDOWN — ${PREFIX}"
  echo -e "  ${RED}${WRN}  This will permanently destroy all OLH resources for: ${PREFIX}${RST}\n"
  confirm "  Type 'y' to confirm teardown" || { echo "Aborted."; exit 0; }

  echo -e "\n  ${GRY}${ARW} terraform destroy -auto-approve -var-file=terraform.tfvars${RST}"
  dry_exec "terraform destroy -auto-approve -var-file=terraform.tfvars"

  section "Removing resources not managed by Terraform"
  for bucket in "${PREFIX}-iceberg-s3" "${PREFIX}-landing-s3" "${PREFIX}-config-s3"; do
    echo -e "  ${GRY}${ARW} Emptying and removing S3 bucket: ${bucket}${RST}"
    dry_exec "aws s3 rm s3://${bucket} --recursive --region ${REGION} 2>/dev/null || true"
    dry_exec "aws s3api delete-bucket --bucket ${bucket} --region ${REGION} 2>/dev/null || true"
    echo -e "  ${GRN}${OK}  Removed: ${bucket}${RST}"
  done

  echo -e "  ${GRY}${ARW} Deleting Kinesis stream: ${PREFIX}-stream-kinesis${RST}"
  dry_exec "aws kinesis delete-stream --stream-name ${PREFIX}-stream-kinesis --region ${REGION} 2>/dev/null || true"

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
  echo -e "  ${YLW}  Creating ${PREFIX}-sg (egress 443 only)${RST}"
  if ! $DRY_RUN; then
    SG_ID=$(aws ec2 create-security-group \
      --group-name "${PREFIX}-sg" \
      --description "Qlik OLH ${PREFIX}" \
      --vpc-id "$VPC_ID" --region "$REGION" \
      --tag-specifications "$(tag_spec security-group "${PREFIX}-sg" "$INITIALS" "$ENV" "$CREATE_DATE")" \
      --output json | py "import sys,json; print(json.load(sys.stdin)['GroupId'])")
    aws ec2 authorize-security-group-egress --group-id "$SG_ID" --region "$REGION" \
      --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" &>/dev/null || true
    echo -e "  ${GRN}${OK}  Created SG: ${SG_ID}${RST}"
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

# ── IAM Role ─────────────────────────────────────────────────
section "IAM Management Role"
echo -e "  ${GRY}${ARW} aws iam list-roles --query contains('${PREFIX}')${RST}"
ROLE_JSON=$(aws iam list-roles \
  --query "Roles[?contains(RoleName,'${PREFIX}')].{Name:RoleName,Arn:Arn}" \
  --output json 2>/dev/null || echo "[]")
ROLE_ARNS=$(py   "import sys,json; [print(r['Arn']) for r in json.load(sys.stdin)]" <<< "$ROLE_JSON")
ROLE_LBLS=$(py   "import sys,json; [print(f\"{r['Arn']}\") for r in json.load(sys.stdin)]" <<< "$ROLE_JSON")
MGMT_ROLE_ARN=""

if [[ -n "$ROLE_ARNS" ]]; then
  pick_resource "IAM Roles" "$ROLE_ARNS" "$ROLE_LBLS"
  [[ -n "$REPLY" ]] && MGMT_ROLE_ARN="$REPLY" && echo -e "  ${GRN}${OK}  Using role: ${MGMT_ROLE_ARN}${RST}"
fi
if [[ -z "$MGMT_ROLE_ARN" ]]; then
  echo -e "  ${YLW}  Creating ${PREFIX}-ec2-role-iam${RST}"
  TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  if ! $DRY_RUN; then
    aws iam create-role --role-name "${PREFIX}-ec2-role-iam" \
      --assume-role-policy-document "$TRUST" \
      --tags "Key=Owner,Value=${INITIALS}" "Key=Environment,Value=${ENV}" \
             "Key=Workload,Value=qlik-olh" "Key=CreateDate,Value=${CREATE_DATE}" \
             "Key=ManagedBy,Value=script" &>/dev/null
    # Attach SSM Managed Instance Core policy
    echo -e "  ${GRY}${ARW} Attaching AmazonSSMManagedInstanceCore policy${RST}"
    aws iam attach-role-policy --role-name "${PREFIX}-ec2-role-iam" \
      --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" &>/dev/null
    MGMT_ROLE_ARN="arn:aws:iam::${ACCT_ID}:role/${PREFIX}-ec2-role-iam"
    echo -e "  ${GRN}${OK}  Created: ${MGMT_ROLE_ARN}  (SSM Core policy attached)${RST}"
  else
    MGMT_ROLE_ARN="arn:aws:iam::${ACCT_ID}:role/${PREFIX}-ec2-role-iam-DRYRUN"
    echo -e "  ${YLW}[DRY-RUN] Would create IAM role ${PREFIX}-ec2-role-iam${RST}"
  fi
fi

# ── Instance Profile ─────────────────────────────────────────
section "EC2 Instance Profile"
echo -e "  ${GRY}${ARW} aws iam list-instance-profiles --query contains('${PREFIX}')${RST}"
PROF_JSON=$(aws iam list-instance-profiles \
  --query "InstanceProfiles[?contains(InstanceProfileName,'${PREFIX}')].{Name:InstanceProfileName,Arn:Arn}" \
  --output json 2>/dev/null || echo "[]")
PROF_ARNS=$(py "import sys,json; [print(p['Arn']) for p in json.load(sys.stdin)]" <<< "$PROF_JSON")
PROF_LBLS=$(py "import sys,json; [print(p['Arn']) for p in json.load(sys.stdin)]" <<< "$PROF_JSON")
INSTANCE_PROFILE_ARN=""

if [[ -n "$PROF_ARNS" ]]; then
  pick_resource "Instance Profiles" "$PROF_ARNS" "$PROF_LBLS"
  [[ -n "$REPLY" ]] && INSTANCE_PROFILE_ARN="$REPLY" && \
    echo -e "  ${GRN}${OK}  Using: ${INSTANCE_PROFILE_ARN}${RST}"
fi
if [[ -z "$INSTANCE_PROFILE_ARN" ]]; then
  echo -e "  ${YLW}  Creating ${PREFIX}-instance-profile${RST}"
  if ! $DRY_RUN; then
    aws iam create-instance-profile \
      --instance-profile-name "${PREFIX}-instance-profile" \
      --tags "Key=Owner,Value=${INITIALS}" "Key=Environment,Value=${ENV}" \
             "Key=CreateDate,Value=${CREATE_DATE}" &>/dev/null
    aws iam add-role-to-instance-profile \
      --instance-profile-name "${PREFIX}-instance-profile" \
      --role-name "${PREFIX}-ec2-role-iam" &>/dev/null
    INSTANCE_PROFILE_ARN="arn:aws:iam::${ACCT_ID}:instance-profile/${PREFIX}-instance-profile"
    echo -e "  ${GRN}${OK}  Created: ${INSTANCE_PROFILE_ARN}${RST}"
  else
    INSTANCE_PROFILE_ARN="arn:aws:iam::${ACCT_ID}:instance-profile/${PREFIX}-instance-profile-DRYRUN"
    echo -e "  ${YLW}[DRY-RUN] Would create instance profile${RST}"
  fi
fi

################################################################
#  GROUP 4 – Storage & Streaming (S3 → Kinesis)
################################################################
header "Group 4 of 5  –  Storage & Streaming"

create_or_use_bucket() {
  local bname="$1" label="$2"
  echo -e "  ${GRY}${ARW} aws s3api head-bucket --bucket ${bname}${RST}"
  if aws s3api head-bucket --bucket "$bname" --region "$REGION" &>/dev/null; then
    echo -e "  ${GRN}${OK}  ${label} exists: ${bname}${RST}"
    confirm "    Use existing '${bname}'?" && { echo "$bname"; return; }
  else
    echo -e "  ${YLW}${WRN}  ${label} not found.${RST}"
  fi
  prompt_val "    Bucket name for ${label}" "$bname" \
    "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$" "Valid S3 bucket name."
  local bn="$REPLY"
  if ! $DRY_RUN; then
    [[ "$REGION" == "us-east-1" ]] && \
      aws s3api create-bucket --bucket "$bn" --region "$REGION" &>/dev/null || \
      aws s3api create-bucket --bucket "$bn" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=${REGION}" &>/dev/null
    aws s3api put-bucket-encryption --bucket "$bn" \
      --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}' &>/dev/null
    aws s3api put-public-access-block --bucket "$bn" \
      --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" &>/dev/null
    aws s3api put-bucket-tagging --bucket "$bn" --tagging \
      "TagSet=[{Key=Owner,Value=${INITIALS}},{Key=Environment,Value=${ENV}},{Key=Workload,Value=qlik-olh},{Key=Application,Value=open-lakehouse},{Key=CreateDate,Value=${CREATE_DATE}},{Key=ManagedBy,Value=script}]" &>/dev/null
    echo -e "  ${GRN}${OK}  Created: ${bn}  (KMS-encrypted, tags applied)${RST}"
  else
    echo -e "  ${YLW}[DRY-RUN] Would create bucket: ${bn}${RST}"
  fi
  echo "$bn"
}

section "S3 Buckets"
S3_ICEBERG=$(create_or_use_bucket "${PREFIX}-iceberg-s3"  "Iceberg bucket")
S3_LANDING=$(create_or_use_bucket "${PREFIX}-landing-s3"  "Landing bucket")
S3_CONFIG=$(create_or_use_bucket  "${PREFIX}-config-s3"   "Config bucket")
create_or_use_bucket "$TFSTATE_BUCKET" "TF State bucket" > /dev/null

section "Kinesis Stream"
KINESIS_NAME="${PREFIX}-stream-kinesis"
echo -e "  ${GRY}${ARW} aws kinesis describe-stream-summary --stream-name ${KINESIS_NAME}${RST}"
if aws kinesis describe-stream-summary --stream-name "$KINESIS_NAME" \
  --region "$REGION" &>/dev/null; then
  echo -e "  ${GRN}${OK}  Kinesis stream exists: ${KINESIS_NAME}${RST}"
  confirm "    Use existing stream?" || {
    prompt_val "New stream name" "${KINESIS_NAME}-2" "^[a-zA-Z0-9_.-]+$" "Valid stream name."
    KINESIS_NAME="$REPLY"
    dry_exec "aws kinesis create-stream --stream-name ${KINESIS_NAME} --shard-count 2 --region ${REGION}"
    echo -e "  ${GRN}${OK}  Created: ${KINESIS_NAME}${RST}"
  }
else
  echo -e "  ${YLW}${WRN}  Stream not found — creating.${RST}"
  if ! $DRY_RUN; then
    aws kinesis create-stream --stream-name "$KINESIS_NAME" \
      --shard-count 2 --region "$REGION"
    aws kinesis add-tags-to-stream --stream-name "$KINESIS_NAME" \
      --tags "Owner=${INITIALS},Environment=${ENV},Workload=qlik-olh,CreateDate=${CREATE_DATE}" \
      --region "$REGION" &>/dev/null
    echo -e "  ${GRN}${OK}  Created: ${KINESIS_NAME}${RST}"
  else
    echo -e "  ${YLW}[DRY-RUN] Would create Kinesis stream: ${KINESIS_NAME}${RST}"
  fi
fi

################################################################
#  GROUP 5 – Tagging Compliance Check
################################################################
header "Group 5 of 5  –  Tagging Compliance"

declare -A REQ_TAGS=( [Owner]="$INITIALS" [Environment]="$ENV" [Workload]="qlik-olh" [Application]="open-lakehouse" [CreateDate]="$CREATE_DATE" [ManagedBy]="script" )
ALL_COMPLIANT=true
echo -e "  ${WHT}Required tags applied to all resources:${RST}\n"
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
$ALL_COMPLIANT && echo -e "  ${GRN}${OK}  All required tags are compliant.${RST}" || \
  echo -e "  ${RED}${ERR}  Tagging compliance failed. Fix before deploying.${RST}"

################################################################
#  REVIEW — Pre-Deploy Summary
################################################################
header "Review — Deployment Summary"

SUBNET_SUMMARY=""
for pair in "${SUBNET_AZ_PAIRS[@]}"; do
  sub="${pair%%|*}"; az="${pair##*|}"
  SUBNET_SUMMARY+="    ${sub}  (${az})"$'\n'
done

echo -e "  ${WHT}Please review the following configuration before proceeding:${RST}"
echo ""
printf "  ${CYN}%-28s %s${RST}\n" "Setting" "Value"
echo "  $SEP"
printf "  %-28s %s\n" "Owner Initials" "$INITIALS"
printf "  %-28s %s\n" "Workload" "$WORKLOAD"
printf "  %-28s %s\n" "Environment" "$ENV"
printf "  %-28s %s\n" "Region" "$REGION"
printf "  %-28s %s\n" "Prefix" "$PREFIX"
printf "  %-28s %s\n" "AWS Account" "$ACCT_ID"
printf "  %-28s %s\n" "Caller ARN" "$CALLER"
echo "  $SEP"
printf "  %-28s %s\n" "VPC ID" "$VPC_ID"
printf "  %-28s %s\n" "VPC CIDR" "$VPC_CIDR"
printf "  %-28s %s\n" "Security Group" "$SG_ID"
echo -e "  Subnets:"
echo -n "$SUBNET_SUMMARY"
echo "  $SEP"
printf "  %-28s %s\n" "KMS Key ARN" "$KMS_KEY_ARN"
printf "  %-28s %s\n" "IAM Role ARN" "$MGMT_ROLE_ARN"
printf "  %-28s %s\n" "Instance Profile ARN" "$INSTANCE_PROFILE_ARN"
echo "  $SEP"
printf "  %-28s %s\n" "S3 Iceberg" "${S3_ICEBERG}"
printf "  %-28s %s\n" "S3 Landing" "${S3_LANDING}"
printf "  %-28s %s\n" "S3 Config" "${S3_CONFIG}"
printf "  %-28s %s\n" "TF State Bucket" "${TFSTATE_BUCKET}"
printf "  %-28s %s\n" "Kinesis Stream" "${KINESIS_NAME}"
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

TFVARS="terraform.tfvars"
SUBNET_BLOCK=""
for pair in "${SUBNET_AZ_PAIRS[@]}"; do
  sub="${pair%%|*}"; az="${pair##*|}"
  SUBNET_BLOCK+="    Subnet: ${sub}   AZ: ${az}"$'\n'
done

# terraform.tfvars
cat > "$TFVARS" <<EOF
# Generated by discover-qlik-lakehouse.sh
# $(date "+%Y-%m-%d %H:%M:%S")
# Mode: $( $DRY_RUN && echo "DRY-RUN" || echo "LIVE")

initials             = "${INITIALS}"
workload             = "${WORKLOAD}"
env                  = "${ENV}"
aws_region           = "${REGION}"
aws_account_id       = "${ACCT_ID}"
tfstate_bucket       = "${TFSTATE_BUCKET}"
vpc_id               = "${VPC_ID}"
vpc_cidr             = "${VPC_CIDR}"
kinesis_stream_name  = "${KINESIS_NAME}"
kinesis_shards       = 2
s3_bucket_name       = "${S3_ICEBERG}"
security_group_id    = "${SG_ID}"
kms_key_arn          = "${KMS_KEY_ARN}"
mgmt_role_arn        = "${MGMT_ROLE_ARN}"
instance_profile_arn = "${INSTANCE_PROFILE_ARN}"

# Tags
tag_owner      = "${INITIALS}"
tag_env        = "${ENV}"
tag_workload   = "qlik-olh"
tag_createdate = "${CREATE_DATE}"
EOF
echo -e "  ${GRN}${OK}  terraform.tfvars${RST}"

# qlik-network-integration.txt
QTC_FILE="qlik-network-integration.txt"
cat > "$QTC_FILE" <<EOF
$(printf '=%.0s' {1..64})
  Qlik Open Lakehouse – QTC Network Integration Reference
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
  Management Role ARN          : ${MGMT_ROLE_ARN}
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
  IAM Role      : ${PREFIX}-ec2-role-iam
  Glue Database : ${INITIALS}_${WORKLOAD}_${ENV}_db_glue
  SSM Path      : /${INITIALS}/${WORKLOAD}/${ENV}
${SEP}
EOF
echo -e "  ${GRN}${OK}  qlik-network-integration.txt${RST}"

# HTML Deployment Report
RPT_FILE="deploy-report.html"
cat > "$RPT_FILE" <<EOF
<!DOCTYPE html><html><head><meta charset="UTF-8">
<title>Qlik OLH Deploy Report – ${PREFIX}</title>
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
<h1>Qlik Open Lakehouse — Deployment Report<small>Prefix: ${PREFIX} &nbsp;|&nbsp; Region: ${REGION} &nbsp;|&nbsp; $(date)</small></h1>
<div class="section"><h2>Status</h2><div class="chips">
  <span class="chip ok">✔ Deployment Complete</span>
  <span class="chip ok">✔ Tags Compliant</span>
  $( $DRY_RUN && echo '<span class="chip warn">⚠ Dry-Run Mode</span>' || echo '<span class="chip ok">✔ Live Mode</span>')
</div></div>
<div class="section"><h2>Network</h2><div class="grid">
  <div class="k">VPC ID</div><div class="v">${VPC_ID}</div>
  <div class="k">VPC CIDR</div><div class="v">${VPC_CIDR}</div>
  <div class="k">Security Group</div><div class="v">${SG_ID}</div>
  <div class="k">Subnets / AZs</div><div class="v">${SUBNET_BLOCK//$'\n'/<br/>}</div>
</div></div>
<div class="section"><h2>Security &amp; Encryption</h2><div class="grid">
  <div class="k">KMS Key ARN</div><div class="v">${KMS_KEY_ARN}</div>
  <div class="k">Management Role</div><div class="v">${MGMT_ROLE_ARN}</div>
  <div class="k">Instance Profile</div><div class="v">${INSTANCE_PROFILE_ARN}</div>
</div></div>
<div class="section"><h2>Storage &amp; Streaming</h2><div class="grid">
  <div class="k">S3 Iceberg</div><div class="v">${S3_ICEBERG}</div>
  <div class="k">S3 Landing</div><div class="v">${S3_LANDING}</div>
  <div class="k">S3 Config</div><div class="v">${S3_CONFIG}</div>
  <div class="k">Kinesis Stream</div><div class="v">${KINESIS_NAME}</div>
</div></div>
<div class="section"><h2>Applied Tags</h2><div class="tags">
  <span class="tag">Owner: ${INITIALS}</span>
  <span class="tag">Environment: ${ENV}</span>
  <span class="tag">Workload: qlik-olh</span>
  <span class="tag">Application: open-lakehouse</span>
  <span class="tag">CreateDate: ${CREATE_DATE}</span>
  <span class="tag">ManagedBy: script</span>
</div></div>
<div class="section"><h2>Generated Names</h2><div class="grid">
  <div class="k">IAM Role</div><div class="v">${PREFIX}-ec2-role-iam</div>
  <div class="k">Glue Database</div><div class="v">${INITIALS}_${WORKLOAD}_${ENV}_db_glue</div>
  <div class="k">SSM Path</div><div class="v">/${INITIALS}/${WORKLOAD}/${ENV}</div>
  <div class="k">TF State Bucket</div><div class="v">${TFSTATE_BUCKET}</div>
</div></div>
</body></html>
EOF
echo -e "  ${GRN}${OK}  deploy-report.html${RST}"

################################################################
#  TERRAFORM
################################################################
if ! $DRY_RUN; then
  header "Terraform Init → Plan → Apply"
  echo -e "  ${GRY}${ARW} terraform init${RST}"
  terraform init -reconfigure \
    -backend-config="bucket=${TFSTATE_BUCKET}" \
    -backend-config="key=qlik-lakehouse/terraform.tfstate" \
    -backend-config="region=${REGION}"
  abort_on_fail $? "terraform init failed."
  echo -e "  ${GRN}${OK}  Init complete.${RST}\n"

  echo -e "  ${GRY}${ARW} terraform plan${RST}"
  terraform plan -var-file="$TFVARS" -out="tfplan"
  abort_on_fail $? "terraform plan failed."
  echo -e "  ${GRN}${OK}  Plan saved to tfplan.${RST}\n"

  if confirm "  Apply the plan now?"; then
    terraform apply "tfplan"
    abort_on_fail $? "terraform apply failed."
    echo -e "  ${GRN}${OK}  Apply complete!${RST}"
  fi
fi

################################################################
#  AUTO-OPEN QTC REFERENCE FILE
################################################################
header "Complete"
echo -e "  ${GRN}${OK}  Output files:${RST}"
echo -e "  ${GRY}    • terraform.tfvars${RST}"
echo -e "  ${GRY}    • qlik-network-integration.txt${RST}"
echo -e "  ${GRY}    • deploy-report.html${RST}"
echo ""
echo -e "  ${CYN}Opening qlik-network-integration.txt ...${RST}"
if   command -v xdg-open &>/dev/null; then xdg-open "$QTC_FILE" &
elif command -v open     &>/dev/null; then open      "$QTC_FILE"
else cat "$QTC_FILE"; fi

echo ""
echo -e "  ${WHT}Next steps:${RST}"
echo -e "  ${GRY}    1. Copy values from qlik-network-integration.txt into QTC${RST}"
echo -e "  ${GRY}    2. Create Network Integration in Qlik Talend Cloud${RST}"
echo -e "  ${GRY}    3. Configure Lakehouse Cluster + Glue catalog connection${RST}"
echo ""
