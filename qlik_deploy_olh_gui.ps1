################################################################
#  qlik_deploy_olh_gui.ps1
#  Qlik Open Lakehouse -- AWS Auto-Discovery and Deployment
#  Windows Forms GUI Wizard
#  Requires: PowerShell 5.1+, AWS CLI, Terraform (optional)
################################################################
#Requires -Version 5

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Force CWD to the script's own folder. UAC-elevated processes start in
# C:\Windows\System32 by default; without this, terraform.tfvars and the
# other wizard outputs would be written there (and likely fail with EACCES).
if ($PSScriptRoot) { Set-Location -LiteralPath $PSScriptRoot }

# Everything the wizard writes is resolved against this rather than the CWD,
# which a user can change out from under a running form.
$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

#region ── Script-Level State ─────────────────────────────────

$script:State = @{
    Mode             = "Deploy"
    # Target cloud: "aws" (GA) or "gcp" (Private Preview, opened 2 Sep 2026).
    Cloud            = "aws"
    GcloudOk         = $false
    GcloudVersion    = ""
    AwsCliOk         = $false
    AwsCliVersion    = ""
    TerraformOk      = $false
    TerraformVersion = ""
    Initials         = ""
    Workload         = "olh"
    Environment      = "dev"
    Region           = "us-east-1"
    Prefix           = ""
    AccountId        = "unknown"
    CallerArn        = "unknown"
    CreateDate       = (Get-Date -Format "yyyy-MM-dd")
    AwsAuthenticated = $false
    VpcId            = ""
    VpcCidr          = ""
    VpcList          = @()
    SubnetAzPairs    = [System.Collections.ArrayList]::new()
    SubnetList       = @()
    SgId             = ""
    SgList           = @()
    CreateNewVpc     = $false
    CreateNewSg      = $false
    KmsKeyArn        = ""
    KmsList          = @()
    MgmtRoleArn      = ""
    RoleList         = @()
    InstanceProfileArn = ""
    CreateNewKms     = $false
    S3Iceberg        = ""
    S3Landing        = ""
    S3Config         = ""
    S3TfState        = ""
    KinesisName      = ""
    CurrentStep      = 0
    Deploying        = $false
    # AWS Auth
    AuthMethod       = "profile"          # profile | accesskey | sso
    AwsProfile       = ""
    AwsAccessKeyId   = ""
    AwsSecretKey     = ""
    AwsSessionToken  = ""
    SsoProfile       = ""

    # ── QTC tenant binding (AWS) ──
    # The management role's trust policy is built from these. Without them QTC
    # has nothing it can assume and the network integration never connects.
    QtcExternalId      = ""
    QlikProxyRoleArn   = ""
    NodeRoleArn        = ""
    S3GatewayEndpoint  = ""

    # ── Google Cloud ──
    GcpAuthMethod    = "current"          # current | login | keyfile
    GcpKeyFile       = ""
    GcpProjectId     = ""
    GcpProjectNumber = ""
    GcpProjectList   = @()
    GcpZones         = @()
    GcpAuthenticated = $false
    GcpAccount       = ""
    NetworkName      = ""
    NetworkList      = @()
    SubnetworkName   = ""
    SubnetworkCidr   = ""
    SubnetworkList   = @()
    PrivateGoogleAccess = $false
    FirewallRule     = ""
    NatRouter        = ""
    NatName          = ""
    GcpKmsKeyId      = ""
    GcpKmsKeyRing    = ""
    GcpKmsKeyName    = ""
    MgmtServiceAccount = ""
    NodeServiceAccount = ""
    GcsTable         = ""
    GcsLanding       = ""
    GcsConfig        = ""
    GcsTfState       = ""
    QtcTenantId      = ""
    QtcAuthMethod    = "workload_identity" # workload_identity | preauthorized_sa
    QtcOidcIssuer    = "https://auth.qlik.com/oauth/token"
}

$script:Controls = @{}
$script:Panels   = @()

#endregion

#region ── Color Constants (Qlik Brand Theme) ────────────────

$script:QlikGreen      = [System.Drawing.Color]::FromArgb(0, 152, 69)       # #009845 - Primary brand green
$script:QlikDarkGreen  = [System.Drawing.Color]::FromArgb(21, 96, 55)       # #156037 - Hover / active green
$script:QlikNavy       = [System.Drawing.Color]::FromArgb(25, 66, 104)      # #194268 - Dark headings
$script:QlikTeal       = [System.Drawing.Color]::FromArgb(0, 101, 128)      # #006580 - Secondary accent
$script:QlikCyan       = [System.Drawing.Color]::FromArgb(16, 207, 201)     # #10CFC9 - Bright accent
$script:QlikGray       = [System.Drawing.Color]::FromArgb(84, 86, 90)       # #54565A - Brand gray
$script:LightGreen     = [System.Drawing.Color]::FromArgb(232, 245, 237)    # #E8F5ED - Light green tint
$script:BgColor        = [System.Drawing.Color]::FromArgb(245, 247, 245)    # #F5F7F5 - Form background
$script:DarkBg         = [System.Drawing.Color]::FromArgb(26, 26, 26)       # #1A1A1A - Log background
$script:LogFg          = [System.Drawing.Color]::FromArgb(204, 204, 204)    # #CCCCCC - Log text

# Aliases for backward compat in code
$script:Blue      = $script:QlikGreen
$script:LightBlue = $script:LightGreen

#endregion

#region ── Helper Functions ───────────────────────────────────

function Write-Log {
    param(
        [string]$Message,
        [System.Drawing.Color]$Color = $script:LogFg,
        [switch]$Bold
    )
    $rtb = $script:Controls['rtbLog']
    if (-not $rtb) { return }
    if ($rtb.InvokeRequired) {
        $rtb.Invoke([Action[string, System.Drawing.Color]]{
            param($m, $c)
            $rtb.SelectionStart  = $rtb.TextLength
            $rtb.SelectionLength = 0
            $rtb.SelectionColor  = $c
            $rtb.AppendText("$m`r`n")
            $rtb.ScrollToCaret()
        }, @($Message, $Color))
    } else {
        $rtb.SelectionStart  = $rtb.TextLength
        $rtb.SelectionLength = 0
        $rtb.SelectionColor  = $Color
        if ($Bold) {
            $rtb.SelectionFont = New-Object System.Drawing.Font($rtb.Font, [System.Drawing.FontStyle]::Bold)
        }
        $rtb.AppendText("$Message`r`n")
        $rtb.ScrollToCaret()
    }
}

function Write-LogGreen  { param([string]$M) Write-Log $M ([System.Drawing.Color]::FromArgb(0, 200, 100)) }
function Write-LogRed    { param([string]$M) Write-Log $M ([System.Drawing.Color]::FromArgb(244,135,113)) }
function Write-LogYellow { param([string]$M) Write-Log $M ([System.Drawing.Color]::FromArgb(220,200,100)) }
function Write-LogCyan   { param([string]$M) Write-Log $M ([System.Drawing.Color]::FromArgb(16,207,201)) }
function Write-LogGray   { param([string]$M) Write-Log $M ([System.Drawing.Color]::FromArgb(150,150,150)) }

function Compute-Prefix {
    $s = $script:State
    if ($s.Initials -and $s.Workload -and $s.Environment) {
        $s.Prefix = "$($s.Initials)-$($s.Workload)-$($s.Environment)"
    } else {
        $s.Prefix = ""
    }
}

function Build-TagSpec {
    param([string]$Type, [string]$Name)
    $s = $script:State
    $tags  = "Key=Name,Value=$Name "
    $tags += "Key=Owner,Value=$($s.Initials) "
    $tags += "Key=Environment,Value=$($s.Environment) "
    $tags += "Key=Workload,Value=qlik-olh "
    $tags += "Key=Application,Value=open-lakehouse "
    $tags += "Key=CreateDate,Value=$($s.CreateDate) "
    $tags += "Key=ManagedBy,Value=script"
    return "ResourceType=$Type,Tags=[{$($tags.Trim() -replace ' ','},{' )}]"
}

function Get-CloudLabel {
    if ($script:State.Cloud -eq "gcp") { return "Google Cloud" } else { return "AWS" }
}

function Get-TerraformDir {
    # Each cloud has its own Terraform root module: they need different
    # backends (S3 vs GCS) and Terraform allows only one backend per config.
    $sub = if ($script:State.Cloud -eq "gcp") { "gcp" } else { "aws" }
    return (Join-Path $script:ScriptDir (Join-Path "terraform" $sub))
}

function Build-GcpLabels {
    # GCP labels are stricter than AWS tags: lowercase letters, digits,
    # hyphens and underscores only.
    $s = $script:State
    return "owner=$($s.Initials),environment=$($s.Environment),workload=qlik-olh,application=open-lakehouse,createdate=$($s.CreateDate),managedby=script"
}

function Invoke-GcloudCmd {
    # Thin alias over Invoke-AwsCmd, which is really just "run this exe and
    # give me stdout". Kept separate so GCP call sites read clearly.
    param([string]$Command, [switch]$AsJson, [switch]$Silent)
    return (Invoke-AwsCmd -Command $Command -AsJson:$AsJson -Silent:$Silent)
}

function Invoke-AwsCmd {
    param([string]$Command, [switch]$AsJson, [switch]$Silent)
    if (-not $Silent) { Write-LogGray "  -> $Command" }
    try {
        $parts = $Command -split ' ', 2
        $exe   = $parts[0]
        $args  = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $exe
        $psi.Arguments              = $args
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        # Drain both pipes asynchronously BEFORE WaitForExit -- reading one to
        # end while the other fills its 4 KB buffer deadlocks both processes.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $stdout = ""; $stderr = ""
        try { if ($outTask.Wait(5000)) { $stdout = $outTask.Result } } catch { }
        try { if ($errTask.Wait(5000)) { $stderr = $errTask.Result } } catch { }
        if ($proc.ExitCode -ne 0) {
            if (-not $Silent -and $stderr) { Write-LogRed "  !! $stderr" }
            return $null
        }
        if ($AsJson -and $stdout) {
            return ($stdout | ConvertFrom-Json)
        }
        return $stdout.Trim()
    } catch {
        if (-not $Silent) { Write-LogRed "  !! Error: $_" }
        return $null
    }
}

#endregion

#region ── UI Factory Functions ───────────────────────────────

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 200, [int]$H = 22, [switch]$Bold, [int]$FontSize = 9)
    $l = New-Object System.Windows.Forms.Label
    $l.Text     = $Text
    $l.Location = [System.Drawing.Point]::new($X, $Y)
    $l.Size     = [System.Drawing.Size]::new($W, $H)
    $l.AutoSize = $false
    if ($Bold) {
        $l.Font = New-Object System.Drawing.Font("Segoe UI", $FontSize, [System.Drawing.FontStyle]::Bold)
    }
    return $l
}

function New-TextBox {
    param([string]$Name, [int]$X, [int]$Y, [int]$W = 200, [string]$Default = "")
    $t = New-Object System.Windows.Forms.TextBox
    $t.Name     = $Name
    $t.Text     = $Default
    $t.Location = [System.Drawing.Point]::new($X, $Y)
    $t.Size     = [System.Drawing.Size]::new($W, 22)
    $script:Controls[$Name] = $t
    return $t
}

function New-ComboBox {
    param([string]$Name, [int]$X, [int]$Y, [int]$W = 200, [string[]]$Items = @(), [string]$Default = "", [switch]$Editable)
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Name     = $Name
    $c.Location = [System.Drawing.Point]::new($X, $Y)
    $c.Size     = [System.Drawing.Size]::new($W, 22)
    if (-not $Editable) { $c.DropDownStyle = 'DropDownList' }
    foreach ($item in $Items) { $c.Items.Add($item) | Out-Null }
    if ($Default -and $c.Items.Contains($Default)) {
        $c.SelectedItem = $Default
    } elseif ($c.Items.Count -gt 0) {
        $c.SelectedIndex = 0
    }
    $script:Controls[$Name] = $c
    return $c
}

function New-Btn {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 100, [int]$H = 28, [scriptblock]$OnClick)
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Location  = [System.Drawing.Point]::new($X, $Y)
    $b.Size      = [System.Drawing.Size]::new($W, $H)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 210, 200)
    if ($OnClick) { $b.Add_Click($OnClick) }
    return $b
}

function New-Sep {
    param([int]$X, [int]$Y, [int]$W = 720)
    $s = New-Object System.Windows.Forms.Label
    $s.Location    = [System.Drawing.Point]::new($X, $Y)
    $s.Size        = [System.Drawing.Size]::new($W, 2)
    $s.BorderStyle = 'Fixed3D'
    return $s
}

function Get-AwsProfiles {
    $profiles = [System.Collections.ArrayList]::new()
    # Read from ~/.aws/credentials
    $credFile = Join-Path $env:USERPROFILE ".aws\credentials"
    if (Test-Path $credFile) {
        Get-Content $credFile | ForEach-Object {
            if ($_ -match '^\[(.+)\]$') { $profiles.Add($Matches[1]) | Out-Null }
        }
    }
    # Read from ~/.aws/config (profiles prefixed with "profile ")
    $cfgFile = Join-Path $env:USERPROFILE ".aws\config"
    if (Test-Path $cfgFile) {
        Get-Content $cfgFile | ForEach-Object {
            if ($_ -match '^\[profile\s+(.+)\]$') {
                if (-not $profiles.Contains($Matches[1])) { $profiles.Add($Matches[1]) | Out-Null }
            }
            elseif ($_ -match '^\[(.+)\]$' -and $Matches[1] -ne 'default') {
                if (-not $profiles.Contains($Matches[1])) { $profiles.Add($Matches[1]) | Out-Null }
            }
        }
    }
    # Ensure "default" is first if present
    if ($profiles.Contains("default")) {
        $profiles.Remove("default")
        $profiles.Insert(0, "default")
    }
    return $profiles
}

function Apply-AwsAuth {
    $s = $script:State
    switch ($s.AuthMethod) {
        "accesskey" {
            if ($s.AwsAccessKeyId -and $s.AwsSecretKey) {
                $env:AWS_ACCESS_KEY_ID     = $s.AwsAccessKeyId
                $env:AWS_SECRET_ACCESS_KEY = $s.AwsSecretKey
                if ($s.AwsSessionToken) { $env:AWS_SESSION_TOKEN = $s.AwsSessionToken }
                else { Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue }
                Remove-Item Env:\AWS_PROFILE -ErrorAction SilentlyContinue
                Write-LogGreen "  OK  Access Key credentials applied to session"
            }
        }
        "profile" {
            if ($s.AwsProfile) {
                $env:AWS_PROFILE = $s.AwsProfile
                Remove-Item Env:\AWS_ACCESS_KEY_ID     -ErrorAction SilentlyContinue
                Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
                Remove-Item Env:\AWS_SESSION_TOKEN     -ErrorAction SilentlyContinue
                Write-LogGreen "  OK  Using AWS profile: $($s.AwsProfile)"
            }
        }
        "sso" {
            if ($s.SsoProfile) {
                $env:AWS_PROFILE = $s.SsoProfile
                Remove-Item Env:\AWS_ACCESS_KEY_ID     -ErrorAction SilentlyContinue
                Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
                Remove-Item Env:\AWS_SESSION_TOKEN     -ErrorAction SilentlyContinue
                Write-LogGreen "  OK  Using SSO profile: $($s.SsoProfile)"
            }
        }
    }
}

#endregion

#region ── Step 0: Welcome ────────────────────────────────────

function Get-LatestTerraformVersion {
    # Ensure TLS 1.2 (PS 5.1 default is too old for HashiCorp / GitHub)
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor `
            [Net.SecurityProtocolType]::Tls12
    } catch { }
    # Try official HashiCorp releases API first, fall back to checkpoint API
    try {
        $r = Invoke-WebRequest -Uri "https://api.releases.hashicorp.com/v1/releases/terraform/latest" -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop | Select-Object -ExpandProperty Content | ConvertFrom-Json
        if ($r.version) { return $r.version }
    } catch { }
    try {
        $r = Invoke-WebRequest -Uri "https://checkpoint-api.hashicorp.com/v1/check/terraform" -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop | Select-Object -ExpandProperty Content | ConvertFrom-Json
        if ($r.current_version) { return $r.current_version }
    } catch { }
    return $null
}

function Get-LatestAwsCliVersion {
    # Fetch latest AWS CLI v2 tag from GitHub. Anonymous calls are rate-limited
    # (60/hr per IP) but a wizard run hits this at most twice -- well under.
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor `
            [Net.SecurityProtocolType]::Tls12
    } catch { }
    try {
        $tags = Invoke-RestMethod -Uri "https://api.github.com/repos/aws/aws-cli/tags?per_page=1" -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        if ($tags -and $tags[0].name) { return $tags[0].name }
    } catch { }
    return $null
}

function Test-VersionOutdated {
    param([string]$Installed, [string]$Latest)
    if (-not $Installed -or -not $Latest) { return $false }
    try {
        $a = [version]($Installed -replace '^[vV]','')
        $b = [version]($Latest    -replace '^[vV]','')
        return ($a -lt $b)
    } catch { return $false }
}

function Run-ToolCheck {
    if ($script:State.Cloud -eq "gcp") { Run-ToolCheckGcp; return }

    # AWS CLI check
    $awsFound = [bool](Get-Command "aws" -ErrorAction SilentlyContinue)
    $script:State.AwsCliOk = $awsFound
    if ($awsFound) {
        $awsInstalled = $null
        try {
            $raw = (aws --version 2>&1) -replace "`n",""
            if ($raw -match 'aws-cli/([\d\.]+)') { $awsInstalled = $Matches[1] }
        } catch { }
        $v = if ($awsInstalled) { "v$awsInstalled" } else { "found" }
        $script:State.AwsCliVersion = $v

        $awsLatest = Get-LatestAwsCliVersion
        if ($awsLatest -and $awsInstalled -and (Test-VersionOutdated $awsInstalled $awsLatest)) {
            $script:Controls['lblAwsStatus'].Text = "[ ! ]  AWS CLI - $v installed, latest is v$awsLatest"
            $script:Controls['lblAwsStatus'].ForeColor = [System.Drawing.Color]::FromArgb(180,130,0)
            $script:Controls['btnInstallAws'].Text    = "Update to v$awsLatest..."
            $script:Controls['btnInstallAws'].Visible = $true
        } else {
            $latestNote = if ($awsLatest) { " (latest: v$awsLatest)" } else { "" }
            $script:Controls['lblAwsStatus'].Text = "[OK]  AWS CLI - $v$latestNote"
            $script:Controls['lblAwsStatus'].ForeColor = [System.Drawing.Color]::DarkGreen
            $script:Controls['btnInstallAws'].Text    = "Reinstall AWS CLI..."
            $script:Controls['btnInstallAws'].Visible = $true
        }
    } else {
        $script:Controls['lblAwsStatus'].Text = "[ X ]  AWS CLI - NOT FOUND (required)"
        $script:Controls['lblAwsStatus'].ForeColor = [System.Drawing.Color]::Red
        $script:Controls['btnInstallAws'].Text    = "Install AWS CLI..."
        $script:Controls['btnInstallAws'].Visible = $true
    }

    # Terraform check
    $tfFound = [bool](Get-Command "terraform" -ErrorAction SilentlyContinue)
    $script:State.TerraformOk = $tfFound
    if ($tfFound) {
        try { $tfInstalled = (terraform version -json 2>$null | ConvertFrom-Json).terraform_version } catch { $tfInstalled = $null }
        $v = if ($tfInstalled) { "v$tfInstalled" } else { "found" }
        $script:State.TerraformVersion = $v

        $tfLatest = Get-LatestTerraformVersion
        if ($tfLatest -and $tfInstalled -and (Test-VersionOutdated $tfInstalled $tfLatest)) {
            $script:Controls['lblTfStatus'].Text = "[ ! ]  Terraform - $v installed, latest is v$tfLatest"
            $script:Controls['lblTfStatus'].ForeColor = [System.Drawing.Color]::FromArgb(180,130,0)
            $script:Controls['btnInstallTf'].Text    = "Update to v$tfLatest..."
            $script:Controls['btnInstallTf'].Visible = $true
        } else {
            $latestNote = if ($tfLatest) { " (latest: v$tfLatest)" } else { "" }
            $script:Controls['lblTfStatus'].Text = "[OK]  Terraform - $v$latestNote"
            $script:Controls['lblTfStatus'].ForeColor = [System.Drawing.Color]::DarkGreen
            $script:Controls['btnInstallTf'].Text    = "Reinstall Terraform..."
            $script:Controls['btnInstallTf'].Visible = $true
        }
    } else {
        $script:Controls['lblTfStatus'].Text = "[ ! ]  Terraform - not found (optional)"
        $script:Controls['lblTfStatus'].ForeColor = [System.Drawing.Color]::FromArgb(180,130,0)
        $script:Controls['btnInstallTf'].Text    = "Install Terraform..."
        $script:Controls['btnInstallTf'].Visible = $true
    }

    Write-LogGreen "  Tool check complete."
    if ($awsFound) { Write-LogGreen "  OK  AWS CLI: $($script:State.AwsCliVersion)" }
    else           { Write-LogRed   "  X   AWS CLI not found - required!" }
    if ($tfFound)  { Write-LogGreen "  OK  Terraform: $($script:State.TerraformVersion)" }
    else           { Write-LogYellow "  !!  Terraform not found - deploy steps will be skipped" }
}

function Run-ToolCheckGcp {
    # gcloud check. Unlike the AWS CLI there is no GitHub tag to compare
    # against - gcloud carries its own updater - so we report the version and
    # leave updating to "gcloud components update".
    $gFound = [bool](Get-Command "gcloud" -ErrorAction SilentlyContinue)
    $script:State.GcloudOk = $gFound
    $script:State.AwsCliOk = $true   # not required on this path; keeps Validate-Step 0 simple

    if ($gFound) {
        $gVer = $null
        try {
            $raw = (gcloud version 2>&1) -join " "
            if ($raw -match 'Google Cloud SDK ([\d\.]+)') { $gVer = $Matches[1] }
        } catch { }
        $v = if ($gVer) { "v$gVer" } else { "found" }
        $script:State.GcloudVersion = $v
        $script:Controls['lblAwsStatus'].Text = "[OK]  Google Cloud CLI - $v"
        $script:Controls['lblAwsStatus'].ForeColor = [System.Drawing.Color]::DarkGreen
        $script:Controls['btnInstallAws'].Text    = "Reinstall gcloud..."
        $script:Controls['btnInstallAws'].Visible = $true
    } else {
        $script:State.GcloudVersion = ""
        $script:Controls['lblAwsStatus'].Text = "[ X ]  Google Cloud CLI - NOT FOUND (required)"
        $script:Controls['lblAwsStatus'].ForeColor = [System.Drawing.Color]::Red
        $script:Controls['btnInstallAws'].Text    = "Install gcloud..."
        $script:Controls['btnInstallAws'].Visible = $true
    }

    # Terraform check is identical on both clouds.
    $tfFound = [bool](Get-Command "terraform" -ErrorAction SilentlyContinue)
    $script:State.TerraformOk = $tfFound
    if ($tfFound) {
        try { $tfInstalled = (terraform version -json 2>$null | ConvertFrom-Json).terraform_version } catch { $tfInstalled = $null }
        $v = if ($tfInstalled) { "v$tfInstalled" } else { "found" }
        $script:State.TerraformVersion = $v
        $tfLatest = Get-LatestTerraformVersion
        if ($tfLatest -and $tfInstalled -and (Test-VersionOutdated $tfInstalled $tfLatest)) {
            $script:Controls['lblTfStatus'].Text = "[ ! ]  Terraform - $v installed, latest is v$tfLatest"
            $script:Controls['lblTfStatus'].ForeColor = [System.Drawing.Color]::FromArgb(180,130,0)
            $script:Controls['btnInstallTf'].Text    = "Update to v$tfLatest..."
        } else {
            $latestNote = if ($tfLatest) { " (latest: v$tfLatest)" } else { "" }
            $script:Controls['lblTfStatus'].Text = "[OK]  Terraform - $v$latestNote"
            $script:Controls['lblTfStatus'].ForeColor = [System.Drawing.Color]::DarkGreen
            $script:Controls['btnInstallTf'].Text    = "Reinstall Terraform..."
        }
        $script:Controls['btnInstallTf'].Visible = $true
    } else {
        $script:Controls['lblTfStatus'].Text = "[ ! ]  Terraform - not found (optional)"
        $script:Controls['lblTfStatus'].ForeColor = [System.Drawing.Color]::FromArgb(180,130,0)
        $script:Controls['btnInstallTf'].Text    = "Install Terraform..."
        $script:Controls['btnInstallTf'].Visible = $true
    }

    Write-LogGreen "  Tool check complete."
    if ($gFound) { Write-LogGreen "  OK  gcloud: $($script:State.GcloudVersion)" }
    else         { Write-LogRed   "  X   Google Cloud CLI not found - required!" }
    if ($tfFound) { Write-LogGreen "  OK  Terraform: $($script:State.TerraformVersion)" }
    else          { Write-LogYellow "  !!  Terraform not found - deploy steps will be skipped" }
}

function Install-GcloudSdk {
    # Google ships a Windows installer; run it interactively so the user keeps
    # control of install location and PATH changes.
    $url = "https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe"
    $dest = Join-Path $env:TEMP "GoogleCloudSDKInstaller.exe"
    Write-LogCyan "  Downloading Google Cloud CLI installer..."
    Write-LogGray  "  -> $url"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    } catch {
        Write-LogRed "  !! Download failed: $_"
        [System.Windows.Forms.MessageBox]::Show(
            "Could not download the installer. Install manually from:`n`nhttps://cloud.google.com/sdk/docs/install",
            "Download failed", 'OK', 'Error') | Out-Null
        return
    }
    Write-LogGreen "  Downloaded. Launching installer..."
    try {
        Start-Process -FilePath $dest -Wait
    } catch {
        Write-LogRed "  !! Could not start the installer: $_"
        return
    }
    # The installer edits PATH for new processes; refresh ours so the tool
    # check can see gcloud without a restart.
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
    Run-ToolCheck
}

function Show-InstallDialog {
    param([string]$Tool)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Install $Tool"; $dlg.Size = [System.Drawing.Size]::new(480, 320)
    $dlg.StartPosition = "CenterParent"; $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $dlg.Controls.Add((New-Label "Choose installation method for $Tool`:" 15 15 440 22 -Bold))

    $hasWinget = [bool](Get-Command "winget" -ErrorAction SilentlyContinue)
    $hasChoco  = [bool](Get-Command "choco"  -ErrorAction SilentlyContinue)

    $y = 50
    # Winget option
    $rbWinget = New-Object System.Windows.Forms.RadioButton
    $rbWinget.Text = "Install via winget (Windows Package Manager)"
    $rbWinget.Location = [System.Drawing.Point]::new(20, $y); $rbWinget.Size = [System.Drawing.Size]::new(420, 22)
    $rbWinget.Enabled = $hasWinget; $rbWinget.Checked = $hasWinget
    if (-not $hasWinget) { $rbWinget.ForeColor = [System.Drawing.Color]::Gray }
    $dlg.Controls.Add($rbWinget)
    $y += 28

    # Chocolatey option
    $rbChoco = New-Object System.Windows.Forms.RadioButton
    $rbChoco.Text = "Install via Chocolatey"
    $rbChoco.Location = [System.Drawing.Point]::new(20, $y); $rbChoco.Size = [System.Drawing.Size]::new(420, 22)
    $rbChoco.Enabled = $hasChoco
    if (-not $hasWinget -and $hasChoco) { $rbChoco.Checked = $true }
    if (-not $hasChoco) { $rbChoco.ForeColor = [System.Drawing.Color]::Gray }
    $dlg.Controls.Add($rbChoco)
    $y += 28

    # Direct download option
    $rbDownload = New-Object System.Windows.Forms.RadioButton
    $rbDownload.Text = "Download and install automatically"
    $rbDownload.Location = [System.Drawing.Point]::new(20, $y); $rbDownload.Size = [System.Drawing.Size]::new(420, 22)
    if (-not $hasWinget -and -not $hasChoco) { $rbDownload.Checked = $true }
    $dlg.Controls.Add($rbDownload)
    $y += 28

    # Manual option
    $rbManual = New-Object System.Windows.Forms.RadioButton
    $rbManual.Text = "Show manual install instructions"
    $rbManual.Location = [System.Drawing.Point]::new(20, $y); $rbManual.Size = [System.Drawing.Size]::new(420, 22)
    $dlg.Controls.Add($rbManual)
    $y += 35

    # Progress label
    $lblProg = New-Label "" 20 $y 430 40
    $lblProg.ForeColor = [System.Drawing.Color]::Gray
    $dlg.Controls.Add($lblProg)

    $btnInstall = New-Btn "Install" 170 ($y + 50) 130 35 {
        $lblProg.Text = "Installing..."
        $lblProg.ForeColor = [System.Drawing.Color]::Gray
        $this.Enabled = $false
        [System.Windows.Forms.Application]::DoEvents()

        # ── Force TLS 1.2 (PS 5.1 default is too old for HashiCorp / AWS) ──
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor `
                [Net.SecurityProtocolType]::Tls12
        } catch { }

        # ── Detect admin (MSI / system-wide installs need it) ─────────────
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                   ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

        # ── Helper: refresh PATH from registry + verify install ───────────
        function Refresh-Path-And-Find($exe) {
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("PATH","User")
            $cmd = Get-Command $exe -ErrorAction SilentlyContinue
            if ($cmd) { return $true }
            # Fallback: probe known install paths
            $candidates = if ($exe -eq "aws") {
                @("$env:ProgramFiles\Amazon\AWSCLIV2\aws.exe",
                  "${env:ProgramFiles(x86)}\Amazon\AWSCLIV2\aws.exe")
            } else {
                @("C:\HashiCorp\Terraform\terraform.exe",
                  "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\HashiCorp.Terraform_*\terraform.exe",
                  "C:\ProgramData\chocolatey\bin\terraform.exe")
            }
            foreach ($c in $candidates) {
                $found = Get-Item $c -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) {
                    $env:PATH = "$env:PATH;$($found.Directory.FullName)"
                    return $true
                }
            }
            return $false
        }

        $success = $false
        $errMsg  = $null
        # Hard cap on package-manager installs: the window is hidden, so a
        # stalled winget/choco would otherwise freeze the wizard indefinitely.
        $installTimeoutMs = 600000

        try {
            if ($rbWinget.Checked) {
                $pkgId = if ($Tool -eq "Terraform") { "HashiCorp.Terraform" } else { "Amazon.AWSCLI" }
                $lblProg.Text = "Running: winget install $pkgId ..."
                [System.Windows.Forms.Application]::DoEvents()
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "winget"
                # --disable-interactivity: the window is hidden, so any prompt
                # winget raises would sit there unseen forever.
                $psi.Arguments = "install --id $pkgId --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements"
                $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
                $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                # Drain both pipes asynchronously BEFORE WaitForExit -- winget's
                # progress output fills the undrained buffer and deadlocks both.
                $outTask = $proc.StandardOutput.ReadToEndAsync()
                $errTask = $proc.StandardError.ReadToEndAsync()
                if (-not $proc.WaitForExit($installTimeoutMs)) {
                    try { $proc.Kill() } catch { }
                    throw "winget did not finish within $([int]($installTimeoutMs / 60000)) minutes. Run 'winget install --id $pkgId' in a terminal to see what it is waiting on."
                }
                # Bounded waits: a grandchild installer can hold the pipe open
                # after winget itself has exited.
                $stdout = ""; $stderr = ""
                try { if ($outTask.Wait(5000)) { $stdout = $outTask.Result } } catch { }
                try { if ($errTask.Wait(5000)) { $stderr = $errTask.Result } } catch { }
                # winget exit codes: 0 = OK, -1978335189 = no applicable update, others = fail
                if ($proc.ExitCode -ne 0) {
                    $errMsg = "winget exit $($proc.ExitCode). $($stderr.Trim()) $($stdout.Trim())".Trim()
                }
                $exe = if ($Tool -eq "Terraform") { "terraform" } else { "aws" }
                $success = Refresh-Path-And-Find $exe

            } elseif ($rbChoco.Checked) {
                $pkgId = if ($Tool -eq "Terraform") { "terraform" } else { "awscli" }
                $lblProg.Text = "Running: choco install $pkgId -y ..."
                [System.Windows.Forms.Application]::DoEvents()
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                # --no-progress: choco's progress bar is the output that fills
                # the pipe; -y already covers the prompts.
                $psi.FileName = "choco"; $psi.Arguments = "install $pkgId -y --no-progress"
                $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
                $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                $outTask = $proc.StandardOutput.ReadToEndAsync()
                $errTask = $proc.StandardError.ReadToEndAsync()
                if (-not $proc.WaitForExit($installTimeoutMs)) {
                    try { $proc.Kill() } catch { }
                    throw "choco did not finish within $([int]($installTimeoutMs / 60000)) minutes. Run 'choco install $pkgId -y' in a terminal to see what it is waiting on."
                }
                $stdout = ""; $stderr = ""
                try { if ($outTask.Wait(5000)) { $stdout = $outTask.Result } } catch { }
                try { if ($errTask.Wait(5000)) { $stderr = $errTask.Result } } catch { }
                if ($proc.ExitCode -ne 0) {
                    $errMsg = "choco exit $($proc.ExitCode). $($stderr.Trim()) $($stdout.Trim())".Trim()
                }
                $exe = if ($Tool -eq "Terraform") { "terraform" } else { "aws" }
                $success = Refresh-Path-And-Find $exe

            } elseif ($rbDownload.Checked) {
                if ($Tool -eq "Terraform") {
                    $lblProg.Text = "Fetching latest Terraform version..."
                    [System.Windows.Forms.Application]::DoEvents()
                    $tfVer = $null
                    try {
                        $rel = Invoke-RestMethod -Uri "https://api.releases.hashicorp.com/v1/releases/terraform/latest" -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                        if ($rel.version) { $tfVer = $rel.version }
                    } catch { }
                    if (-not $tfVer) {
                        try {
                            $rel = Invoke-RestMethod -Uri "https://checkpoint-api.hashicorp.com/v1/check/terraform" -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                            if ($rel.current_version) { $tfVer = $rel.current_version }
                        } catch { }
                    }
                    if (-not $tfVer) { $tfVer = "1.15.0" }

                    $tfZip  = "$env:TEMP\terraform_${tfVer}_windows_amd64.zip"
                    $tfDest = "C:\HashiCorp\Terraform"
                    $tfUrl  = "https://releases.hashicorp.com/terraform/${tfVer}/terraform_${tfVer}_windows_amd64.zip"
                    $lblProg.Text = "Downloading Terraform v$tfVer..."
                    [System.Windows.Forms.Application]::DoEvents()
                    try {
                        Invoke-WebRequest -Uri $tfUrl -OutFile $tfZip -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
                    } catch {
                        $errMsg = "Download failed: $($_.Exception.Message)"
                        throw
                    }
                    if (-not (Test-Path $tfDest)) {
                        try { New-Item -ItemType Directory -Path $tfDest -Force | Out-Null }
                        catch { $errMsg = "Cannot create $tfDest (need admin?). $($_.Exception.Message)"; throw }
                    }
                    try {
                        Expand-Archive -Path $tfZip -DestinationPath $tfDest -Force -ErrorAction Stop
                    } catch {
                        $errMsg = "Cannot extract zip: $($_.Exception.Message)"
                        throw
                    }
                    Remove-Item $tfZip -Force -ErrorAction SilentlyContinue
                    $curPath = [Environment]::GetEnvironmentVariable("PATH","User")
                    if ($curPath -notlike "*$tfDest*") {
                        try {
                            [Environment]::SetEnvironmentVariable("PATH","$curPath;$tfDest","User")
                        } catch {
                            $errMsg = "Installed to $tfDest but could not update User PATH: $($_.Exception.Message)"
                        }
                    }
                    $success = Refresh-Path-And-Find "terraform"

                } else {
                    if (-not $isAdmin) {
                        $errMsg = "AWS CLI MSI install requires Administrator. Re-launch the wizard via run_qlik_deploy_gui.bat (it elevates), or install via winget."
                        throw [System.Exception]::new($errMsg)
                    }
                    $lblProg.Text = "Downloading AWS CLI v2 installer..."
                    [System.Windows.Forms.Application]::DoEvents()
                    $msiPath = "$env:TEMP\AWSCLIV2.msi"
                    try {
                        Invoke-WebRequest -Uri "https://awscli.amazonaws.com/AWSCLIV2.msi" -OutFile $msiPath -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
                    } catch {
                        $errMsg = "Download failed: $($_.Exception.Message)"
                        throw
                    }
                    $lblProg.Text = "Running MSI installer (this may take a minute)..."
                    [System.Windows.Forms.Application]::DoEvents()
                    $logPath = "$env:TEMP\AWSCLIV2-install.log"
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = "msiexec.exe"
                    $psi.Arguments = "/i `"$msiPath`" /qn /norestart /l*v `"$logPath`""
                    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
                    # 1618 = ERROR_INSTALL_ALREADY_RUNNING. Another Windows
                    # Installer transaction (Windows Update, a winget install)
                    # holds the global mutex; it usually clears within a minute.
                    $msiExit = 0
                    for ($attempt = 1; $attempt -le 3; $attempt++) {
                        $proc = [System.Diagnostics.Process]::Start($psi)
                        $proc.WaitForExit()
                        $msiExit = $proc.ExitCode
                        if ($msiExit -ne 1618) { break }
                        if ($attempt -lt 3) {
                            $lblProg.Text = "Another Windows Installer is running; retrying in 20s ($attempt/3)..."
                            [System.Windows.Forms.Application]::DoEvents()
                            Start-Sleep -Seconds 20
                        }
                    }
                    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
                    if ($msiExit -eq 1618) {
                        $errMsg = "Another Windows Installer is already running (msiexec 1618). Wait for it to finish - or reboot if nothing is visibly installing - then retry."
                    } elseif ($msiExit -ne 0) {
                        $errMsg = "msiexec exit $msiExit. See log: $logPath"
                    }
                    $success = Refresh-Path-And-Find "aws"
                }

            } elseif ($rbManual.Checked) {
                if ($Tool -eq "Terraform") {
                    $lblProg.Text = "Opening Terraform download page..."
                    Start-Process "https://developer.hashicorp.com/terraform/downloads"
                } else {
                    $lblProg.Text = "Opening AWS CLI download page..."
                    Start-Process "https://awscli.amazonaws.com/AWSCLIV2.msi"
                }
                $lblProg.Text += "`nInstall manually, then click 'Check Tools' to re-verify."
                $this.Enabled = $true
                return
            }
        } catch {
            if (-not $errMsg) { $errMsg = $_.Exception.Message }
            $success = $false
        }

        if ($success) {
            $lblProg.Text = "$Tool installed successfully!"
            $lblProg.ForeColor = [System.Drawing.Color]::DarkGreen
            Write-LogGreen "  OK  $Tool installed successfully."
            Start-Sleep -Milliseconds 800
            $dlg.DialogResult = 'OK'; $dlg.Close()
        } else {
            if ($errMsg) {
                $shortMsg = if ($errMsg.Length -gt 220) { $errMsg.Substring(0, 220) + "..." } else { $errMsg }
                $lblProg.Text = "Install failed: $shortMsg"
                Write-LogRed "  X  $Tool install failed: $errMsg"
            } else {
                $lblProg.Text = "Install completed but $($Tool.ToLower()) is not on PATH yet. Close and re-open the wizard."
                Write-LogYellow "  !!  $Tool installed but not on PATH; restart shell."
            }
            $lblProg.ForeColor = [System.Drawing.Color]::FromArgb(180,130,0)
            $this.Enabled = $true
        }
    }
    $btnInstall.BackColor = $script:Blue; $btnInstall.ForeColor = [System.Drawing.Color]::White
    $btnInstall.FlatAppearance.BorderSize = 0
    $dlg.Controls.Add($btnInstall)

    $dlg.ShowDialog() | Out-Null
    # Re-run tool check after dialog closes
    Run-ToolCheck
}

function Build-Step0 {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'

    $p.Controls.Add((New-Label "Welcome to Qlik Open Lakehouse Deployment Wizard" 20 8 720 26 -Bold -FontSize 12))

    # ── Target cloud ──
    # Asked first, because it decides which CLI the tool check demands and
    # which set of wizard pages follows.
    $grpCloud = New-Object System.Windows.Forms.GroupBox
    $grpCloud.Text     = "Target Cloud"
    $grpCloud.Location = [System.Drawing.Point]::new(20, 38)
    $grpCloud.Size     = [System.Drawing.Size]::new(720, 76)

    $rbAws = New-Object System.Windows.Forms.RadioButton
    $rbAws.Text = "Amazon Web Services"; $rbAws.Location = [System.Drawing.Point]::new(15, 24)
    $rbAws.Size = [System.Drawing.Size]::new(180, 22); $rbAws.Checked = $true
    $rbAws.Add_CheckedChanged({ if ($this.Checked) { Set-Cloud "aws" } })
    $script:Controls['rbCloudAws'] = $rbAws
    $grpCloud.Controls.Add($rbAws)

    $lblAwsGa = New-Label "generally available" 200 26 130
    $lblAwsGa.ForeColor = [System.Drawing.Color]::Gray
    $lblAwsGa.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $grpCloud.Controls.Add($lblAwsGa)

    $rbGcp = New-Object System.Windows.Forms.RadioButton
    $rbGcp.Text = "Google Cloud"; $rbGcp.Location = [System.Drawing.Point]::new(360, 24)
    $rbGcp.Size = [System.Drawing.Size]::new(140, 22)
    $rbGcp.Add_CheckedChanged({ if ($this.Checked) { Set-Cloud "gcp" } })
    $script:Controls['rbCloudGcp'] = $rbGcp
    $grpCloud.Controls.Add($rbGcp)

    $lblGcpPrev = New-Label "Private Preview" 505 26 130
    $lblGcpPrev.ForeColor = [System.Drawing.Color]::FromArgb(180,130,0)
    $lblGcpPrev.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $grpCloud.Controls.Add($lblGcpPrev)

    $lblCloudNote = New-Label "" 15 48 690 20
    $lblCloudNote.ForeColor = [System.Drawing.Color]::Gray
    $lblCloudNote.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $script:Controls['lblCloudNote'] = $lblCloudNote
    $grpCloud.Controls.Add($lblCloudNote)

    $p.Controls.Add($grpCloud)

    # Tool Status GroupBox - full width for better readability
    $grpTools = New-Object System.Windows.Forms.GroupBox
    $grpTools.Text     = "Prerequisite Tools"
    $grpTools.Location = [System.Drawing.Point]::new(20, 120)
    $grpTools.Size     = [System.Drawing.Size]::new(720, 140)

    # AWS CLI row
    $lblAws = New-Label "[ ? ]  AWS CLI - not checked" 15 28 400 22
    $lblAws.Name = "lblAwsStatus"
    $script:Controls['lblAwsStatus'] = $lblAws
    $grpTools.Controls.Add($lblAws)

    $btnInstAws = New-Btn "Install AWS CLI..." 490 25 120 26 {
        if ($script:State.Cloud -eq "gcp") { Install-GcloudSdk } else { Show-InstallDialog "AWS CLI" }
    }
    $btnInstAws.Visible = $false
    $script:Controls['btnInstallAws'] = $btnInstAws
    $grpTools.Controls.Add($btnInstAws)

    # Terraform row
    $lblTf = New-Label "[ ? ]  Terraform - not checked" 15 58 400 22
    $lblTf.Name = "lblTfStatus"
    $script:Controls['lblTfStatus'] = $lblTf
    $grpTools.Controls.Add($lblTf)

    $btnInstTf = New-Btn "Install Terraform..." 490 55 120 26 { Show-InstallDialog "Terraform" }
    $btnInstTf.Visible = $false
    $script:Controls['btnInstallTf'] = $btnInstTf
    $grpTools.Controls.Add($btnInstTf)

    # Buttons row
    $btnCheck = New-Btn "Check Tools" 15 95 120 30 { Run-ToolCheck }
    $grpTools.Controls.Add($btnCheck)

    $lblCheckHint = New-Label "Verifies the cloud CLI and Terraform are installed and on PATH" 145 100 400
    $lblCheckHint.ForeColor = [System.Drawing.Color]::Gray
    $lblCheckHint.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $grpTools.Controls.Add($lblCheckHint)

    $btnInstBoth = New-Btn "Install Both..." 620 95 90 30 {
        if ($script:State.Cloud -eq "gcp") {
            if (-not $script:State.GcloudOk) { Install-GcloudSdk }
            if (-not $script:State.TerraformOk) { Show-InstallDialog "Terraform" }
            if ($script:State.GcloudOk -and $script:State.TerraformOk) {
                [System.Windows.Forms.MessageBox]::Show("Both tools are already installed.", "Info", 'OK', 'Information') | Out-Null
            }
            return
        }
        if (-not $script:State.AwsCliOk) { Show-InstallDialog "AWS CLI" }
        if (-not $script:State.TerraformOk) { Show-InstallDialog "Terraform" }
        if ($script:State.AwsCliOk -and $script:State.TerraformOk) {
            [System.Windows.Forms.MessageBox]::Show("Both tools are already installed.", "Info", 'OK', 'Information') | Out-Null
        }
    }
    $grpTools.Controls.Add($btnInstBoth)

    $p.Controls.Add($grpTools)

    # Mode GroupBox
    $grpMode = New-Object System.Windows.Forms.GroupBox
    $grpMode.Text     = "Deployment Mode"
    $grpMode.Location = [System.Drawing.Point]::new(20, 266)
    $grpMode.Size     = [System.Drawing.Size]::new(720, 100)

    $rbDeploy = New-Object System.Windows.Forms.RadioButton
    $rbDeploy.Text = "Deploy (Live)"; $rbDeploy.Location = [System.Drawing.Point]::new(15, 25)
    $rbDeploy.Size = [System.Drawing.Size]::new(150, 22); $rbDeploy.Checked = $true
    $rbDeploy.Add_CheckedChanged({ if ($this.Checked) { $script:State.Mode = "Deploy" } })
    $grpMode.Controls.Add($rbDeploy)

    $rbDry = New-Object System.Windows.Forms.RadioButton
    $rbDry.Text = "Dry-Run (simulate)"; $rbDry.Location = [System.Drawing.Point]::new(180, 25)
    $rbDry.Size = [System.Drawing.Size]::new(160, 22)
    $rbDry.Add_CheckedChanged({ if ($this.Checked) { $script:State.Mode = "DryRun" } })
    $grpMode.Controls.Add($rbDry)

    $rbDrift = New-Object System.Windows.Forms.RadioButton
    $rbDrift.Text = "Drift Check"; $rbDrift.Location = [System.Drawing.Point]::new(360, 25)
    $rbDrift.Size = [System.Drawing.Size]::new(130, 22)
    $rbDrift.Add_CheckedChanged({ if ($this.Checked) { $script:State.Mode = "Drift" } })
    $script:Controls['rbModeDrift'] = $rbDrift
    $grpMode.Controls.Add($rbDrift)

    $rbTear = New-Object System.Windows.Forms.RadioButton
    $rbTear.Text = "Teardown"; $rbTear.Location = [System.Drawing.Point]::new(510, 25)
    $rbTear.Size = [System.Drawing.Size]::new(130, 22); $rbTear.ForeColor = [System.Drawing.Color]::Red
    $rbTear.Add_CheckedChanged({
        if ($this.Checked) {
            $script:State.Mode = "Teardown"
            $script:Controls['lblTeardownWarn'].Visible = $true
        } else {
            $script:Controls['lblTeardownWarn'].Visible = $false
        }
    })
    $script:Controls['rbModeTeardown'] = $rbTear
    $script:Controls['rbModeDeploy']   = $rbDeploy
    $grpMode.Controls.Add($rbTear)

    $lblWarn = New-Label "WARNING: Resources will be permanently deleted!" 15 55 690 22
    $lblWarn.ForeColor = [System.Drawing.Color]::Red
    $lblWarn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lblWarn.Visible = $false
    $script:Controls['lblTeardownWarn'] = $lblWarn
    $grpMode.Controls.Add($lblWarn)

    $p.Controls.Add($grpMode)
    return $p
}

#endregion

#region ── Step 1: Identity & AWS Credentials ────────────────

function Show-HideAuthPanels {
    $script:Controls['pnlAuthProfile'].Visible   = ($script:State.AuthMethod -eq "profile")
    $script:Controls['pnlAuthAccessKey'].Visible  = ($script:State.AuthMethod -eq "accesskey")
    $script:Controls['pnlAuthSso'].Visible        = ($script:State.AuthMethod -eq "sso")
}

function Verify-AwsIdentity {
    $btn = $script:Controls['btnVerifyAws']
    $btn.Enabled = $false; $btn.Text = "Checking..."
    [System.Windows.Forms.Application]::DoEvents()

    # Apply the chosen auth method first
    Apply-AwsAuth
    Write-LogGray "  Checking AWS authentication..."

    $json = Invoke-AwsCmd "aws sts get-caller-identity --output json --region $($script:State.Region)" -AsJson -Silent
    if ($json) {
        $script:State.AccountId  = $json.Account
        $script:State.CallerArn  = $json.Arn
        $script:State.AwsAuthenticated = $true
        $script:Controls['lblAwsIdentity'].Text = "Account: $($json.Account)  |  $($json.Arn)"
        $script:Controls['lblAwsIdentity'].ForeColor = [System.Drawing.Color]::DarkGreen
        Write-LogGreen "  OK  Authenticated: $($json.Arn)"
        Write-LogGreen "  OK  Account ID:    $($json.Account)"
    } else {
        $script:State.AwsAuthenticated = $false
        $script:Controls['lblAwsIdentity'].Text = "Not authenticated. Check credentials and try again."
        $script:Controls['lblAwsIdentity'].ForeColor = [System.Drawing.Color]::Red
        Write-LogYellow "  !!  AWS authentication failed."
    }
    $btn.Enabled = $true; $btn.Text = "Verify Identity"
}

function Build-Step1 {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'

    # ── Identity Row (compact: 2 columns) ──
    $p.Controls.Add((New-Label "Identity and Naming" 20 5 350 22 -Bold -FontSize 10))

    # Row 1: Initials + Workload
    $p.Controls.Add((New-Label "Initials:" 20 32 70))
    $txtInit = New-TextBox "txtInitials" 90 29 100
    $txtInit.MaxLength = 6
    $txtInit.Add_TextChanged({
        $this.Text = $this.Text.ToLower(); $this.SelectionStart = $this.Text.Length
        $script:State.Initials = $this.Text; Compute-Prefix
        $script:Controls['lblPrefixValue'].Text = $script:State.Prefix
        $script:Controls['lblInitialsHint'].ForeColor = if ($this.Text -match '^[a-z0-9]{2,6}$') { [System.Drawing.Color]::Gray } else { [System.Drawing.Color]::Red }
    })
    $p.Controls.Add($txtInit)
    $lblIH = New-Label "2-6 a-z/0-9" 195 32 90; $lblIH.ForeColor = [System.Drawing.Color]::Gray; $lblIH.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
    $script:Controls['lblInitialsHint'] = $lblIH
    $p.Controls.Add($lblIH)

    $p.Controls.Add((New-Label "Workload:" 290 32 70))
    $txtWk = New-TextBox "txtWorkload" 360 29 100 "olh"
    $txtWk.Add_TextChanged({
        $this.Text = $this.Text.ToLower(); $this.SelectionStart = $this.Text.Length
        $script:State.Workload = $this.Text; Compute-Prefix
        $script:Controls['lblPrefixValue'].Text = $script:State.Prefix
    })
    $p.Controls.Add($txtWk)

    # Row 2: Environment + Region + Prefix
    $p.Controls.Add((New-Label "Env:" 20 62 35))
    $cboEnv = New-ComboBox "cboEnvironment" 55 59 80 @("dev","uat","prod") "dev"
    $cboEnv.Add_SelectedIndexChanged({
        $script:State.Environment = $this.SelectedItem.ToString(); Compute-Prefix
        $script:Controls['lblPrefixValue'].Text = $script:State.Prefix
    })
    $p.Controls.Add($cboEnv)

    $p.Controls.Add((New-Label "Region:" 150 62 50))
    $regions = @("us-east-1","us-east-2","us-west-1","us-west-2","eu-west-1","eu-west-2","eu-central-1","ap-southeast-1","ap-southeast-2","ap-northeast-1")
    $cboReg = New-ComboBox "cboRegion" 205 59 140 $regions "us-east-1" -Editable
    $cboReg.Add_TextChanged({ $script:State.Region = $this.Text })
    $p.Controls.Add($cboReg)

    $p.Controls.Add((New-Label "Prefix:" 370 62 50 -Bold))
    $lblPfx = New-Label "" 420 62 320
    $lblPfx.ForeColor = $script:Blue
    $lblPfx.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
    $script:Controls['lblPrefixValue'] = $lblPfx
    $p.Controls.Add($lblPfx)

    # ── AWS Credentials GroupBox ──
    $p.Controls.Add((New-Sep 20 90 720))

    $grpAuth = New-Object System.Windows.Forms.GroupBox
    $grpAuth.Text     = "AWS Credentials"
    $grpAuth.Location = [System.Drawing.Point]::new(20, 98)
    $grpAuth.Size     = [System.Drawing.Size]::new(720, 270)

    # Auth method radio buttons (horizontal)
    $rbProfile = New-Object System.Windows.Forms.RadioButton
    $rbProfile.Text = "AWS Profile"; $rbProfile.Location = [System.Drawing.Point]::new(15, 22); $rbProfile.Size = [System.Drawing.Size]::new(120, 20)
    $rbProfile.Checked = $true
    $rbProfile.Add_CheckedChanged({ if ($this.Checked) { $script:State.AuthMethod = "profile"; Show-HideAuthPanels } })
    $grpAuth.Controls.Add($rbProfile)

    $rbAccessKey = New-Object System.Windows.Forms.RadioButton
    $rbAccessKey.Text = "Access Key / Secret"; $rbAccessKey.Location = [System.Drawing.Point]::new(160, 22); $rbAccessKey.Size = [System.Drawing.Size]::new(170, 20)
    $rbAccessKey.Add_CheckedChanged({ if ($this.Checked) { $script:State.AuthMethod = "accesskey"; Show-HideAuthPanels } })
    $grpAuth.Controls.Add($rbAccessKey)

    $rbSso = New-Object System.Windows.Forms.RadioButton
    $rbSso.Text = "AWS SSO"; $rbSso.Location = [System.Drawing.Point]::new(355, 22); $rbSso.Size = [System.Drawing.Size]::new(120, 20)
    $rbSso.Add_CheckedChanged({ if ($this.Checked) { $script:State.AuthMethod = "sso"; Show-HideAuthPanels } })
    $grpAuth.Controls.Add($rbSso)

    # ── Profile sub-panel ──
    $pnlProfile = New-Object System.Windows.Forms.Panel
    $pnlProfile.Location = [System.Drawing.Point]::new(10, 48)
    $pnlProfile.Size     = [System.Drawing.Size]::new(695, 190)
    $script:Controls['pnlAuthProfile'] = $pnlProfile

    $pnlProfile.Controls.Add((New-Label "Profile:" 5 8 65))
    $cboProf = New-ComboBox "cboAwsProfile" 75 5 200 @() "" -Editable
    $cboProf.Add_TextChanged({ $script:State.AwsProfile = $this.Text })
    $pnlProfile.Controls.Add($cboProf)

    $btnRefProf = New-Btn "Reload" 280 4 65 26 {
        $cbo = $script:Controls['cboAwsProfile']
        $cbo.Items.Clear()
        $profiles = Get-AwsProfiles
        foreach ($prof in $profiles) { $cbo.Items.Add($prof) | Out-Null }
        if ($cbo.Items.Count -gt 0) { $cbo.SelectedIndex = 0 }
        Write-LogGreen "  Loaded $($profiles.Count) AWS profile(s)"
    }
    $pnlProfile.Controls.Add($btnRefProf)

    $btnLoadFile = New-Btn "Load File..." 535 4 85 26 {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title  = "Load AWS Credentials File"
        $dlg.Filter = "AWS Credentials|credentials|INI files (*.ini)|*.ini|Config files (*.cfg;*.conf)|*.cfg;*.conf|CSV files (*.csv)|*.csv|All files (*.*)|*.*"
        $dlg.InitialDirectory = if (Test-Path (Join-Path $env:USERPROFILE ".aws")) {
            Join-Path $env:USERPROFILE ".aws"
        } else { $env:USERPROFILE }

        if ($dlg.ShowDialog() -eq 'OK') {
            $filePath = $dlg.FileName
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()

            if ($ext -eq ".csv") {
                # CSV format: profile_name,aws_access_key_id,aws_secret_access_key[,region]
                try {
                    $rows = Import-Csv $filePath -ErrorAction Stop
                    $imported = 0
                    foreach ($row in $rows) {
                        $pName = if ($row.PSObject.Properties['profile_name']) { $row.profile_name }
                                 elseif ($row.PSObject.Properties['Profile Name']) { $row.'Profile Name' }
                                 elseif ($row.PSObject.Properties['User name']) { $row.'User name' }
                                 elseif ($row.PSObject.Properties['User Name']) { $row.'User Name' }
                                 else { "" }
                        $aKey  = if ($row.PSObject.Properties['aws_access_key_id']) { $row.aws_access_key_id }
                                 elseif ($row.PSObject.Properties['Access key ID']) { $row.'Access key ID' }
                                 elseif ($row.PSObject.Properties['Access Key Id']) { $row.'Access Key Id' }
                                 else { "" }
                        $aSec  = if ($row.PSObject.Properties['aws_secret_access_key']) { $row.aws_secret_access_key }
                                 elseif ($row.PSObject.Properties['Secret access key']) { $row.'Secret access key' }
                                 elseif ($row.PSObject.Properties['Secret Access Key']) { $row.'Secret Access Key' }
                                 else { "" }
                        $aReg  = if ($row.PSObject.Properties['region']) { $row.region }
                                 elseif ($row.PSObject.Properties['Region']) { $row.Region }
                                 else { "us-east-1" }

                        if (-not $pName) { $pName = "imported" }
                        if ($aKey -and $aSec) {
                            $credFile = Join-Path $env:USERPROFILE ".aws\credentials"
                            $confFile = Join-Path $env:USERPROFILE ".aws\config"
                            $awsDir   = Join-Path $env:USERPROFILE ".aws"
                            if (-not (Test-Path $awsDir)) { New-Item -ItemType Directory -Path $awsDir -Force | Out-Null }
                            Add-Content -Path $credFile -Value "`n[$pName]`naws_access_key_id = $aKey`naws_secret_access_key = $aSec`n" -Encoding UTF8
                            Add-Content -Path $confFile -Value "`n[profile $pName]`nregion = $aReg`noutput = json`n" -Encoding UTF8
                            $imported++
                        }
                    }
                    Write-LogGreen "  Imported $imported profile(s) from CSV"
                } catch {
                    Write-LogRed "  Failed to parse CSV: $_"
                }
            } else {
                # INI-style credentials file — copy profiles into ~/.aws/credentials
                try {
                    $content = Get-Content $filePath -Raw
                    $credFile = Join-Path $env:USERPROFILE ".aws\credentials"
                    $awsDir   = Join-Path $env:USERPROFILE ".aws"
                    if (-not (Test-Path $awsDir)) { New-Item -ItemType Directory -Path $awsDir -Force | Out-Null }

                    # Parse sections and append any that have access keys
                    $imported = 0
                    $sections = [regex]::Matches($content, '(?ms)^\[([^\]]+)\]\s*\n(.*?)(?=^\[|\z)')
                    foreach ($sec in $sections) {
                        $secName = $sec.Groups[1].Value
                        $secBody = $sec.Groups[2].Value
                        if ($secBody -match 'aws_access_key_id') {
                            Add-Content -Path $credFile -Value "`n[$secName]`n$($secBody.Trim())`n" -Encoding UTF8
                            $imported++
                        }
                    }
                    if ($imported -gt 0) {
                        Write-LogGreen "  Imported $imported profile(s) from $([System.IO.Path]::GetFileName($filePath))"
                    } else {
                        Write-LogYellow "  No credential profiles found in file (expected [profile] sections with aws_access_key_id)"
                    }
                } catch {
                    Write-LogRed "  Failed to read file: $_"
                }
            }

            # Reload profiles dropdown
            $cbo = $script:Controls['cboAwsProfile']
            $cbo.Items.Clear()
            $profiles = Get-AwsProfiles
            foreach ($prof in $profiles) { $cbo.Items.Add($prof) | Out-Null }
            if ($cbo.Items.Count -gt 0) { $cbo.SelectedIndex = $cbo.Items.Count - 1 }
            $cboS = $script:Controls['cboSsoProfile']
            $cboS.Items.Clear()
            foreach ($prof in $profiles) { $cboS.Items.Add($prof) | Out-Null }
        }
    }
    $pnlProfile.Controls.Add($btnLoadFile)

    $pnlProfile.Controls.Add((& {
        $l = New-Label "Select, type a name, or load from file" 5 33 300
        $l.ForeColor = [System.Drawing.Color]::Gray; $l.Font = New-Object System.Drawing.Font("Segoe UI", 8); $l
    }))

    # ── Configure New Profile section ──
    $btnNewProf = New-Btn "Configure New Profile..." 5 52 170 24 {
        $pnl = $script:Controls['pnlNewProfile']
        $pnl.Visible = -not $pnl.Visible
        if ($pnl.Visible) { $this.Text = "Hide New Profile" } else { $this.Text = "Configure New Profile..." }
    }
    $pnlProfile.Controls.Add($btnNewProf)

    $pnlNewProf = New-Object System.Windows.Forms.Panel
    $pnlNewProf.Location = [System.Drawing.Point]::new(0, 78)
    $pnlNewProf.Size     = [System.Drawing.Size]::new(695, 110)
    $pnlNewProf.Visible  = $false
    $script:Controls['pnlNewProfile'] = $pnlNewProf

    $pnlNewProf.Controls.Add((New-Label "Profile name:" 5 5 90))
    $txtNewProfName = New-Object System.Windows.Forms.TextBox
    $txtNewProfName.Location = [System.Drawing.Point]::new(100, 3)
    $txtNewProfName.Size     = [System.Drawing.Size]::new(140, 22)
    $script:Controls['txtNewProfName'] = $txtNewProfName
    $pnlNewProf.Controls.Add($txtNewProfName)

    $pnlNewProf.Controls.Add((New-Label "Access Key ID:" 5 30 90))
    $txtNewKey = New-Object System.Windows.Forms.TextBox
    $txtNewKey.Location = [System.Drawing.Point]::new(100, 28)
    $txtNewKey.Size     = [System.Drawing.Size]::new(200, 22)
    $txtNewKey.UseSystemPasswordChar = $true
    $script:Controls['txtNewProfKeyId'] = $txtNewKey
    $pnlNewProf.Controls.Add($txtNewKey)

    $pnlNewProf.Controls.Add((New-Label "Secret Key:" 5 55 90))
    $txtNewSec = New-Object System.Windows.Forms.TextBox
    $txtNewSec.Location = [System.Drawing.Point]::new(100, 53)
    $txtNewSec.Size     = [System.Drawing.Size]::new(200, 22)
    $txtNewSec.UseSystemPasswordChar = $true
    $script:Controls['txtNewProfSecret'] = $txtNewSec
    $pnlNewProf.Controls.Add($txtNewSec)

    $pnlNewProf.Controls.Add((New-Label "Region:" 310 5 50))
    $txtNewReg = New-Object System.Windows.Forms.TextBox
    $txtNewReg.Location = [System.Drawing.Point]::new(365, 3)
    $txtNewReg.Size     = [System.Drawing.Size]::new(100, 22)
    $txtNewReg.Text     = "us-east-1"
    $script:Controls['txtNewProfRegion'] = $txtNewReg
    $pnlNewProf.Controls.Add($txtNewReg)

    $pnlNewProf.Controls.Add((New-Label "Output:" 310 30 50))
    $cboNewOut = New-ComboBox "cboNewProfOutput" 365 28 100 @("json","text","table","yaml") "json"
    $pnlNewProf.Controls.Add($cboNewOut)

    $chkNewShow = New-Object System.Windows.Forms.CheckBox
    $chkNewShow.Text     = "Show credentials"
    $chkNewShow.Location = [System.Drawing.Point]::new(310, 55)
    $chkNewShow.Size     = [System.Drawing.Size]::new(130, 20)
    $chkNewShow.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
    $chkNewShow.Add_CheckedChanged({
        $show = $this.Checked
        $script:Controls['txtNewProfKeyId'].UseSystemPasswordChar = -not $show
        $script:Controls['txtNewProfSecret'].UseSystemPasswordChar = -not $show
    })
    $pnlNewProf.Controls.Add($chkNewShow)

    $btnSaveProf = New-Btn "Save Profile" 100 82 120 26 {
        $profName  = $script:Controls['txtNewProfName'].Text.Trim()
        $keyId     = $script:Controls['txtNewProfKeyId'].Text.Trim()
        $secret    = $script:Controls['txtNewProfSecret'].Text.Trim()
        $region    = $script:Controls['txtNewProfRegion'].Text.Trim()
        $output    = $script:Controls['cboNewProfOutput'].Text

        if (-not $profName) {
            [System.Windows.Forms.MessageBox]::Show("Profile name is required.", "Validation", 'OK', 'Warning') | Out-Null; return
        }
        if (-not $keyId -or -not $secret) {
            [System.Windows.Forms.MessageBox]::Show("Access Key ID and Secret Key are required.", "Validation", 'OK', 'Warning') | Out-Null; return
        }

        # Write to ~/.aws/credentials
        $credFile = Join-Path $env:USERPROFILE ".aws\credentials"
        $confFile = Join-Path $env:USERPROFILE ".aws\config"
        $awsDir   = Join-Path $env:USERPROFILE ".aws"
        if (-not (Test-Path $awsDir)) { New-Item -ItemType Directory -Path $awsDir -Force | Out-Null }

        # Append credentials
        $credBlock = "`n[$profName]`naws_access_key_id = $keyId`naws_secret_access_key = $secret`n"
        Add-Content -Path $credFile -Value $credBlock -Encoding UTF8

        # Append config
        $confBlock = "`n[profile $profName]`nregion = $region`noutput = $output`n"
        Add-Content -Path $confFile -Value $confBlock -Encoding UTF8

        Write-LogGreen "  Profile '$profName' saved to ~/.aws/credentials and ~/.aws/config"

        # Reload profiles and select the new one
        $cbo = $script:Controls['cboAwsProfile']
        $cbo.Items.Clear()
        $profiles = Get-AwsProfiles
        foreach ($prof in $profiles) { $cbo.Items.Add($prof) | Out-Null }
        $idx = $cbo.Items.IndexOf($profName)
        if ($idx -ge 0) { $cbo.SelectedIndex = $idx }

        # Also reload SSO profile list
        $cboS = $script:Controls['cboSsoProfile']
        $cboS.Items.Clear()
        foreach ($prof in $profiles) { $cboS.Items.Add($prof) | Out-Null }

        # Hide the new profile panel
        $script:Controls['pnlNewProfile'].Visible = $false
        ($script:Controls['pnlNewProfile'].Parent.Controls | Where-Object { $_.Text -eq 'Hide New Profile' }) | ForEach-Object { $_.Text = 'Configure New Profile...' }

        # Clear sensitive fields
        $script:Controls['txtNewProfKeyId'].Text = ""
        $script:Controls['txtNewProfSecret'].Text = ""
    }
    $btnSaveProf.BackColor = $script:QlikGreen
    $btnSaveProf.ForeColor = [System.Drawing.Color]::White
    $btnSaveProf.FlatAppearance.BorderSize = 0
    $pnlNewProf.Controls.Add($btnSaveProf)

    $pnlNewProf.Controls.Add((& {
        $l = New-Label "Saves to ~/.aws/credentials and ~/.aws/config" 230 86 300
        $l.ForeColor = [System.Drawing.Color]::Gray; $l.Font = New-Object System.Drawing.Font("Segoe UI", 8); $l
    }))

    $pnlProfile.Controls.Add($pnlNewProf)

    $grpAuth.Controls.Add($pnlProfile)

    # ── Access Key sub-panel ──
    $pnlAK = New-Object System.Windows.Forms.Panel
    $pnlAK.Location = [System.Drawing.Point]::new(10, 48)
    $pnlAK.Size     = [System.Drawing.Size]::new(695, 110)
    $pnlAK.Visible  = $false
    $script:Controls['pnlAuthAccessKey'] = $pnlAK

    $pnlAK.Controls.Add((New-Label "Access Key ID:" 5 8 110))
    $txtAkId = New-TextBox "txtAwsAccessKey" 120 5 280
    $txtAkId.UseSystemPasswordChar = $true
    $txtAkId.Add_TextChanged({ $script:State.AwsAccessKeyId = $this.Text })
    $pnlAK.Controls.Add($txtAkId)

    $pnlAK.Controls.Add((New-Label "Secret Access Key:" 5 38 110))
    $txtSk = New-TextBox "txtAwsSecretKey" 120 35 280
    $txtSk.UseSystemPasswordChar = $true
    $txtSk.Add_TextChanged({ $script:State.AwsSecretKey = $this.Text })
    $pnlAK.Controls.Add($txtSk)

    $pnlAK.Controls.Add((New-Label "Session Token:" 5 68 110))
    $txtSt = New-TextBox "txtAwsSessionToken" 120 65 280
    $txtSt.UseSystemPasswordChar = $true
    $txtSt.Add_TextChanged({ $script:State.AwsSessionToken = $this.Text })
    $pnlAK.Controls.Add($txtSt)
    $pnlAK.Controls.Add((& {
        $l = New-Label "(optional - for temporary credentials)" 410 68 250
        $l.ForeColor = [System.Drawing.Color]::Gray; $l.Font = New-Object System.Drawing.Font("Segoe UI", 8); $l
    }))

    $chkShowCreds = New-Object System.Windows.Forms.CheckBox
    $chkShowCreds.Text = "Show credentials"; $chkShowCreds.Location = [System.Drawing.Point]::new(410, 8); $chkShowCreds.Size = [System.Drawing.Size]::new(130, 20)
    $chkShowCreds.Add_CheckedChanged({
        $show = -not $this.Checked
        $script:Controls['txtAwsAccessKey'].UseSystemPasswordChar = $show
        $script:Controls['txtAwsSecretKey'].UseSystemPasswordChar = $show
        $script:Controls['txtAwsSessionToken'].UseSystemPasswordChar = $show
    })
    $pnlAK.Controls.Add($chkShowCreds)

    $grpAuth.Controls.Add($pnlAK)

    # ── SSO sub-panel ──
    $pnlSso = New-Object System.Windows.Forms.Panel
    $pnlSso.Location = [System.Drawing.Point]::new(10, 48)
    $pnlSso.Size     = [System.Drawing.Size]::new(695, 110)
    $pnlSso.Visible  = $false
    $script:Controls['pnlAuthSso'] = $pnlSso

    $pnlSso.Controls.Add((New-Label "SSO Profile:" 5 8 100))
    $cboSso = New-ComboBox "cboSsoProfile" 110 5 250 @() "" -Editable
    $cboSso.Add_TextChanged({ $script:State.SsoProfile = $this.Text })
    $pnlSso.Controls.Add($cboSso)

    $btnRefSso = New-Btn "Reload Profiles" 370 4 120 26 {
        $cbo = $script:Controls['cboSsoProfile']
        $cbo.Items.Clear()
        $profiles = Get-AwsProfiles
        foreach ($prof in $profiles) { $cbo.Items.Add($prof) | Out-Null }
        if ($cbo.Items.Count -gt 0) { $cbo.SelectedIndex = 0 }
        Write-LogGreen "  Loaded $($profiles.Count) profile(s)"
    }
    $pnlSso.Controls.Add($btnRefSso)

    $btnSsoLogin = New-Btn "SSO Login" 110 40 120 28 {
        $prof = $script:Controls['cboSsoProfile'].Text
        if (-not $prof) {
            [System.Windows.Forms.MessageBox]::Show("Enter or select an SSO profile name first.", "Info", 'OK', 'Information') | Out-Null
            return
        }
        Write-LogGray "  Launching SSO login for profile: $prof"
        $script:Controls['lblSsoStatus'].Text = "Opening browser for SSO login..."
        $script:Controls['lblSsoStatus'].ForeColor = [System.Drawing.Color]::Gray
        [System.Windows.Forms.Application]::DoEvents()

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "aws"; $psi.Arguments = "sso login --profile $prof"
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()

        if ($proc.ExitCode -eq 0) {
            $script:Controls['lblSsoStatus'].Text = "SSO login successful!"
            $script:Controls['lblSsoStatus'].ForeColor = [System.Drawing.Color]::DarkGreen
            $script:State.SsoProfile = $prof
            Write-LogGreen "  OK  SSO login complete for profile: $prof"
        } else {
            $script:Controls['lblSsoStatus'].Text = "SSO login failed or was cancelled."
            $script:Controls['lblSsoStatus'].ForeColor = [System.Drawing.Color]::Red
            Write-LogRed "  !!  SSO login failed for profile: $prof"
        }
    }
    $btnSsoLogin.BackColor = $script:QlikTeal
    $btnSsoLogin.ForeColor = [System.Drawing.Color]::White
    $btnSsoLogin.FlatAppearance.BorderSize = 0
    $pnlSso.Controls.Add($btnSsoLogin)

    $lblSsoSt = New-Label "Click 'SSO Login' to authenticate via browser" 240 44 400
    $lblSsoSt.ForeColor = [System.Drawing.Color]::Gray; $lblSsoSt.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $script:Controls['lblSsoStatus'] = $lblSsoSt
    $pnlSso.Controls.Add($lblSsoSt)

    $grpAuth.Controls.Add($pnlSso)

    # ── Verify button inside auth groupbox ──
    $btnVerify = New-Btn "Verify Identity" 530 225 170 32 { Verify-AwsIdentity }
    $btnVerify.BackColor = $script:Blue; $btnVerify.ForeColor = [System.Drawing.Color]::White
    $btnVerify.FlatAppearance.BorderSize = 0
    $script:Controls['btnVerifyAws'] = $btnVerify
    $grpAuth.Controls.Add($btnVerify)

    $p.Controls.Add($grpAuth)

    # ── Identity Result ──
    $lblId = New-Label "Configure credentials above, then click 'Verify Identity'." 20 372 720 22
    $lblId.ForeColor = [System.Drawing.Color]::Gray
    $script:Controls['lblAwsIdentity'] = $lblId
    $p.Controls.Add($lblId)

    # Auto-load profiles when step becomes visible
    $p.Add_VisibleChanged({
        if ($this.Visible) {
            $cboP = $script:Controls['cboAwsProfile']
            $cboS = $script:Controls['cboSsoProfile']
            if ($cboP.Items.Count -eq 0) {
                $profiles = Get-AwsProfiles
                foreach ($prof in $profiles) {
                    $cboP.Items.Add($prof) | Out-Null
                    $cboS.Items.Add($prof) | Out-Null
                }
                if ($cboP.Items.Count -gt 0) { $cboP.SelectedIndex = 0; $cboS.SelectedIndex = 0 }
            }
        }
    })

    return $p
}

#endregion

#region ── Step 2: Network ────────────────────────────────────

function Build-Step2 {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'

    $p.Controls.Add((New-Label "Network Configuration" 20 5 720 28 -Bold -FontSize 11))

    # VPC Section
    $p.Controls.Add((New-Label "VPC:" 20 38 50 -Bold))
    $cboVpc = New-ComboBox "cboVpc" 75 35 430
    $cboVpc.Add_SelectedIndexChanged({
        if ($this.SelectedIndex -ge 0 -and $script:State.VpcList.Count -gt $this.SelectedIndex) {
            $sel = $script:State.VpcList[$this.SelectedIndex]
            $script:State.VpcId   = $sel.Id
            $script:State.VpcCidr = $sel.CIDR
        }
    })
    $p.Controls.Add($cboVpc)

    $btnRefVpc = New-Btn "Refresh" 515 34 80 26 {
        $this.Enabled = $false
        Write-LogGray "  Discovering VPCs in $($script:State.Region)..."
        $raw = Invoke-AwsCmd "aws ec2 describe-vpcs --region $($script:State.Region) --query `"Vpcs[*].{Id:VpcId,CIDR:CidrBlock,Name:Tags[?Key=='Name']|[0].Value}`" --output json" -AsJson -Silent
        $cbo = $script:Controls['cboVpc']
        $cbo.Items.Clear()
        $script:State.VpcList = @()
        if ($raw) {
            $script:State.VpcList = @($raw)
            foreach ($v in $raw) {
                $cbo.Items.Add("$($v.Id)  |  $($v.CIDR)  |  $($v.Name)") | Out-Null
            }
            Write-LogGreen "  Found $($raw.Count) VPC(s)"
        } else {
            Write-LogYellow "  No VPCs found"
        }
        $this.Enabled = $true
    }
    $p.Controls.Add($btnRefVpc)

    $chkNewVpc = New-Object System.Windows.Forms.CheckBox
    $chkNewVpc.Text = "Create New"; $chkNewVpc.Location = [System.Drawing.Point]::new(605, 37); $chkNewVpc.Size = [System.Drawing.Size]::new(110, 22)
    $chkNewVpc.Add_CheckedChanged({
        $script:State.CreateNewVpc = $this.Checked
        $script:Controls['cboVpc'].Enabled       = -not $this.Checked
        $script:Controls['lblNewVpcCidr'].Visible = $this.Checked
        $script:Controls['txtNewVpcCidr'].Visible = $this.Checked
    })
    $p.Controls.Add($chkNewVpc)

    $lblCidr = New-Label "New VPC CIDR:" 20 65 110
    $lblCidr.Visible = $false; $script:Controls['lblNewVpcCidr'] = $lblCidr
    $p.Controls.Add($lblCidr)
    $txtCidr = New-TextBox "txtNewVpcCidr" 135 62 180 "10.0.0.0/16"
    $txtCidr.Visible = $false
    $p.Controls.Add($txtCidr)

    # Subnets Section
    $p.Controls.Add((New-Sep 20 95 720))
    $p.Controls.Add((New-Label "Subnets:" 20 105 100 -Bold))

    $lstSub = New-Object System.Windows.Forms.ListBox
    $lstSub.Name = "lstSubnets"; $lstSub.Location = [System.Drawing.Point]::new(20, 130)
    $lstSub.Size = [System.Drawing.Size]::new(580, 90); $lstSub.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:Controls['lstSubnets'] = $lstSub
    $p.Controls.Add($lstSub)

    $btnLoadSub = New-Btn "Load Existing" 610 130 120 28 {
        if (-not $script:State.VpcId -and -not $script:State.CreateNewVpc) {
            [System.Windows.Forms.MessageBox]::Show("Select a VPC first.", "Info", 'OK', 'Information') | Out-Null
            return
        }
        Write-LogGray "  Loading subnets for $($script:State.VpcId)..."
        $raw = Invoke-AwsCmd "aws ec2 describe-subnets --region $($script:State.Region) --filters `"Name=vpc-id,Values=$($script:State.VpcId)`" --query `"Subnets[*].{Id:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}`" --output json" -AsJson -Silent
        if ($raw) {
            $script:State.SubnetList = @($raw)
            # Show picker dialog
            $dlg = New-Object System.Windows.Forms.Form
            $dlg.Text = "Select Subnets"; $dlg.Size = [System.Drawing.Size]::new(500, 350)
            $dlg.StartPosition = "CenterParent"; $dlg.FormBorderStyle = "FixedDialog"
            $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
            $clb = New-Object System.Windows.Forms.CheckedListBox
            $clb.Location = [System.Drawing.Point]::new(10, 10); $clb.Size = [System.Drawing.Size]::new(465, 250)
            $clb.Font = New-Object System.Drawing.Font("Consolas", 9)
            foreach ($s in $raw) {
                $clb.Items.Add("$($s.Id)  AZ:$($s.AZ)  CIDR:$($s.CIDR)", $false) | Out-Null
            }
            $dlg.Controls.Add($clb)
            $btnOk = New-Btn "Add Selected" 170 265 130 30 {
                for ($i = 0; $i -lt $clb.Items.Count; $i++) {
                    if ($clb.GetItemChecked($i)) {
                        $sn = $raw[$i]
                        $exists = $script:State.SubnetAzPairs | Where-Object { $_.Subnet -eq $sn.Id }
                        if (-not $exists) {
                            $script:State.SubnetAzPairs.Add([PSCustomObject]@{ Subnet=$sn.Id; AZ=$sn.AZ; CIDR=$sn.CIDR; IsNew=$false }) | Out-Null
                        }
                    }
                }
                $dlg.DialogResult = 'OK'; $dlg.Close()
            }
            $dlg.Controls.Add($btnOk)
            $dlg.ShowDialog() | Out-Null
            # Refresh listbox
            $lst = $script:Controls['lstSubnets']
            $lst.Items.Clear()
            foreach ($pair in $script:State.SubnetAzPairs) {
                $lst.Items.Add("$($pair.Subnet)  AZ:$($pair.AZ)  CIDR:$($pair.CIDR)") | Out-Null
            }
            Write-LogGreen "  $($script:State.SubnetAzPairs.Count) subnet(s) selected"
        } else {
            Write-LogYellow "  No subnets found in this VPC"
        }
    }
    $p.Controls.Add($btnLoadSub)

    $btnNewSub = New-Btn "Add New..." 610 163 120 28 {
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = "New Subnet"; $dlg.Size = [System.Drawing.Size]::new(380, 200)
        $dlg.StartPosition = "CenterParent"; $dlg.FormBorderStyle = "FixedDialog"
        $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
        $dlg.Controls.Add((New-Label "CIDR (e.g. 10.0.1.0/24):" 15 15 180))
        $tC = New-TextBox "dlgSubCidr" 200 12 150 "10.0.1.0/24"
        $dlg.Controls.Add($tC)
        $dlg.Controls.Add((New-Label "Availability Zone:" 15 50 180))
        $tA = New-TextBox "dlgSubAz" 200 47 150 "$($script:State.Region)a"
        $dlg.Controls.Add($tA)
        $bOk = New-Btn "Add" 130 100 100 30 {
            $cidr = $script:Controls['dlgSubCidr'].Text
            $az   = $script:Controls['dlgSubAz'].Text
            if ($cidr -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') {
                [System.Windows.Forms.MessageBox]::Show("Invalid CIDR format.", "Error", 'OK', 'Error') | Out-Null; return
            }
            if ($az -notmatch '^[a-z]{2}-[a-z]+-[0-9][a-z]$') {
                [System.Windows.Forms.MessageBox]::Show("Invalid AZ format.", "Error", 'OK', 'Error') | Out-Null; return
            }
            $script:State.SubnetAzPairs.Add([PSCustomObject]@{ Subnet="(new)"; AZ=$az; CIDR=$cidr; IsNew=$true }) | Out-Null
            $dlg.DialogResult = 'OK'; $dlg.Close()
        }
        $dlg.Controls.Add($bOk)
        $dlg.ShowDialog() | Out-Null
        # Refresh listbox
        $lst = $script:Controls['lstSubnets']
        $lst.Items.Clear()
        foreach ($pair in $script:State.SubnetAzPairs) {
            $tag = if ($pair.IsNew) { " [NEW]" } else { "" }
            $lst.Items.Add("$($pair.Subnet)  AZ:$($pair.AZ)  CIDR:$($pair.CIDR)$tag") | Out-Null
        }
    }
    $p.Controls.Add($btnNewSub)

    $btnRemSub = New-Btn "Remove" 610 196 120 28 {
        $lst = $script:Controls['lstSubnets']
        if ($lst.SelectedIndex -ge 0) {
            $script:State.SubnetAzPairs.RemoveAt($lst.SelectedIndex)
            $lst.Items.RemoveAt($lst.SelectedIndex)
        }
    }
    $p.Controls.Add($btnRemSub)

    # Security Group Section
    $p.Controls.Add((New-Sep 20 230 720))
    $p.Controls.Add((New-Label "Security Group:" 20 245 130 -Bold))

    $cboSg = New-ComboBox "cboSg" 155 242 350
    $cboSg.Add_SelectedIndexChanged({
        if ($this.SelectedIndex -ge 0 -and $script:State.SgList.Count -gt $this.SelectedIndex) {
            $script:State.SgId = $script:State.SgList[$this.SelectedIndex].Id
        }
    })
    $p.Controls.Add($cboSg)

    $btnRefSg = New-Btn "Refresh" 515 241 80 26 {
        if (-not $script:State.VpcId -and -not $script:State.CreateNewVpc) { return }
        Write-LogGray "  Discovering security groups..."
        $raw = Invoke-AwsCmd "aws ec2 describe-security-groups --region $($script:State.Region) --filters `"Name=vpc-id,Values=$($script:State.VpcId)`" --query `"SecurityGroups[*].{Id:GroupId,Name:GroupName}`" --output json" -AsJson -Silent
        $cbo = $script:Controls['cboSg']
        $cbo.Items.Clear()
        $script:State.SgList = @()
        if ($raw) {
            $script:State.SgList = @($raw)
            foreach ($s in $raw) { $cbo.Items.Add("$($s.Id)  |  $($s.Name)") | Out-Null }
            Write-LogGreen "  Found $($raw.Count) security group(s)"
        }
        $this.Enabled = $true
    }
    $p.Controls.Add($btnRefSg)

    $chkNewSg = New-Object System.Windows.Forms.CheckBox
    $chkNewSg.Text = "Create New"; $chkNewSg.Location = [System.Drawing.Point]::new(605, 244); $chkNewSg.Size = [System.Drawing.Size]::new(110, 22)
    $chkNewSg.Add_CheckedChanged({
        $script:State.CreateNewSg = $this.Checked
        $script:Controls['cboSg'].Enabled = -not $this.Checked
        $script:Controls['lblSgInfo'].Visible = $this.Checked
    })
    $p.Controls.Add($chkNewSg)

    $lblSgInfo = New-Label "" 20 275 700
    $lblSgInfo.ForeColor = [System.Drawing.Color]::FromArgb(180,130,0)
    $lblSgInfo.Visible = $false
    $script:Controls['lblSgInfo'] = $lblSgInfo
    $p.Controls.Add($lblSgInfo)

    # Update SG info when step becomes visible
    $p.Add_VisibleChanged({
        if ($this.Visible) {
            $script:Controls['lblSgInfo'].Text = "Will create: $($script:State.Prefix)-sg (egress HTTPS 443 only)"
        }
    })

    return $p
}

#endregion

#region ── Step 3: Security ───────────────────────────────────

function Build-Step3 {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'

    $p.Controls.Add((New-Label "Security, Identity and Tenant Binding" 20 5 720 26 -Bold -FontSize 11))

    # ── KMS ──
    $p.Controls.Add((New-Label "KMS Symmetric Key" 20 34 300 22 -Bold))

    $cboKms = New-ComboBox "cboKms" 20 58 480
    $cboKms.Add_SelectedIndexChanged({
        if ($this.SelectedIndex -ge 0 -and $script:State.KmsList.Count -gt $this.SelectedIndex) {
            $sel = $script:State.KmsList[$this.SelectedIndex]
            $script:State.KmsKeyArn = "arn:aws:kms:$($script:State.Region):$($script:State.AccountId):key/$($sel.KeyId)"
        }
    })
    $p.Controls.Add($cboKms)

    $btnRefKms = New-Btn "Refresh" 510 57 80 26 {
        Write-LogGray "  Discovering KMS keys..."
        $raw = Invoke-AwsCmd "aws kms list-aliases --region $($script:State.Region) --query `"Aliases[?contains(AliasName,'$($script:State.Prefix)')].{Alias:AliasName,KeyId:TargetKeyId}`" --output json" -AsJson -Silent
        $cbo = $script:Controls['cboKms']
        $cbo.Items.Clear()
        $script:State.KmsList = @()
        if ($raw) {
            $script:State.KmsList = @($raw | Where-Object { $_.KeyId })
            foreach ($k in $script:State.KmsList) { $cbo.Items.Add("$($k.KeyId)  |  $($k.Alias)") | Out-Null }
            Write-LogGreen "  Found $($script:State.KmsList.Count) KMS key(s) matching prefix"
        } else {
            Write-LogYellow "  No KMS keys found with prefix $($script:State.Prefix)"
        }
    }
    $p.Controls.Add($btnRefKms)

    $chkNewKms = New-Object System.Windows.Forms.CheckBox
    $chkNewKms.Text = "Create New"; $chkNewKms.Location = [System.Drawing.Point]::new(600, 60); $chkNewKms.Size = [System.Drawing.Size]::new(110, 22)
    $chkNewKms.Add_CheckedChanged({
        $script:State.CreateNewKms = $this.Checked
        $script:Controls['cboKms'].Enabled = -not $this.Checked
    })
    $p.Controls.Add($chkNewKms)

    # ── IAM roles ──
    $p.Controls.Add((New-Sep 20 94 720))
    $p.Controls.Add((New-Label "IAM Roles" 20 104 300 22 -Bold))

    $lblRoles = New-Label "Two roles are created. The management role is assumed by Qlik from outside your account and carries the ExternalId condition below; the node role is assumed by EC2, goes into the instance profile, and gets the S3/Kinesis/KMS/Glue policy from Terraform." 20 126 720 44
    $lblRoles.ForeColor = [System.Drawing.Color]::Gray
    $lblRoles.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $p.Controls.Add($lblRoles)

    $lblRoleNames = New-Label "" 20 172 720 22
    $lblRoleNames.ForeColor = [System.Drawing.Color]::FromArgb(25, 66, 104)
    $lblRoleNames.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $script:Controls['lblRoleNames'] = $lblRoleNames
    $p.Controls.Add($lblRoleNames)

    # ── QTC tenant binding ──
    $p.Controls.Add((New-Sep 20 200 720))
    $p.Controls.Add((New-Label "Qlik Talend Cloud tenant binding" 20 210 320 22 -Bold))

    $lblBind = New-Label "Both values come from Administration > Network integrations in QTC, on the screen where you create the integration." 20 232 720
    $lblBind.ForeColor = [System.Drawing.Color]::Gray
    $lblBind.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $p.Controls.Add($lblBind)

    $p.Controls.Add((New-Label "ExternalId" 20 260 110))
    $p.Controls.Add((New-TextBox "txtQtcExternalId" 135 258 300))

    $p.Controls.Add((New-Label "Qlik proxy role ARN" 20 292 130))
    $p.Controls.Add((New-TextBox "txtQlikProxyArn" 160 290 560 "arn:aws:iam::000000000000:role/qlik-proxy-assume-role"))

    $lblWhy = New-Label "Without these, the management role has no trust policy Qlik can use and the network integration will never connect." 20 320 720 32
    $lblWhy.ForeColor = [System.Drawing.Color]::FromArgb(180,130,0)
    $lblWhy.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $p.Controls.Add($lblWhy)

    $p.Add_VisibleChanged({
        if ($this.Visible -and $script:Controls['lblRoleNames']) {
            $pfx = $script:State.Prefix
            $script:Controls['lblRoleNames'].Text =
                "management: $pfx-mgmt-role-iam    node: $pfx-ec2-role-iam    profile: $pfx-instance-profile"
        }
    })

    return $p
}

#endregion

#region ── Step 4: Storage ────────────────────────────────────

function Build-Step4 {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'

    $p.Controls.Add((New-Label "Storage and Streaming" 20 5 720 28 -Bold -FontSize 11))

    # S3 Buckets
    $p.Controls.Add((New-Label "S3 Bucket Configuration" 20 40 300 22 -Bold))

    $y = 70
    foreach ($item in @(
        @{ Label="Iceberg Bucket:"; Name="txtS3Iceberg"; Suffix="-iceberg-s3"; StatusName="lblS3IcebergStatus" },
        @{ Label="Landing Bucket:"; Name="txtS3Landing"; Suffix="-landing-s3"; StatusName="lblS3LandingStatus" },
        @{ Label="Config Bucket:";  Name="txtS3Config";  Suffix="-config-s3";  StatusName="lblS3ConfigStatus"  }
    )) {
        $p.Controls.Add((New-Label $item.Label 20 $y 130))
        $txt = New-TextBox $item.Name 155 ($y - 3) 380
        $p.Controls.Add($txt)
        $lbl = New-Label "" 545 $y 190
        $lbl.ForeColor = [System.Drawing.Color]::Gray
        $script:Controls[$item.StatusName] = $lbl
        $p.Controls.Add($lbl)
        $y += 35
    }

    $btnCheckBuckets = New-Btn "Check Bucket Status" 20 ($y + 5) 150 28 {
        foreach ($bkt in @(
            @{ CtrlName="txtS3Iceberg"; StatusName="lblS3IcebergStatus" },
            @{ CtrlName="txtS3Landing"; StatusName="lblS3LandingStatus" },
            @{ CtrlName="txtS3Config";  StatusName="lblS3ConfigStatus"  }
        )) {
            $bn = $script:Controls[$bkt.CtrlName].Text
            if (-not $bn) { continue }
            $result = Invoke-AwsCmd "aws s3api head-bucket --bucket $bn --region $($script:State.Region)" -Silent
            # Invoke-AwsCmd returns $null on failure, "" on head-bucket success.
            # Do NOT consult $LASTEXITCODE here -- it holds a stale value from
            # whatever native command ran last and falsely reports "Exists".
            if ($null -ne $result) {
                $script:Controls[$bkt.StatusName].Text = "Exists"
                $script:Controls[$bkt.StatusName].ForeColor = [System.Drawing.Color]::DarkGreen
            } else {
                $script:Controls[$bkt.StatusName].Text = "Will be created"
                $script:Controls[$bkt.StatusName].ForeColor = [System.Drawing.Color]::FromArgb(180,130,0)
            }
        }
        Write-LogGreen "  Bucket status check complete."
    }
    $p.Controls.Add($btnCheckBuckets)

    # Kinesis
    $p.Controls.Add((New-Sep 20 ($y + 45) 720))
    $ky = $y + 60
    $p.Controls.Add((New-Label "Kinesis Data Stream" 20 $ky 300 22 -Bold))
    $ky += 30
    $p.Controls.Add((New-Label "Stream Name:" 20 $ky 130))
    $txtKin = New-TextBox "txtKinesis" 155 ($ky - 3) 380
    $p.Controls.Add($txtKin)
    $lblKinSt = New-Label "" 545 $ky 190
    $lblKinSt.ForeColor = [System.Drawing.Color]::Gray
    $script:Controls['lblKinesisStatus'] = $lblKinSt
    $p.Controls.Add($lblKinSt)

    $btnCheckStream = New-Btn "Check Stream" 20 ($ky + 30) 130 28 {
        $sn = $script:Controls['txtKinesis'].Text
        if (-not $sn) { return }
        $result = Invoke-AwsCmd "aws kinesis describe-stream-summary --stream-name $sn --region $($script:State.Region)" -Silent
        if ($result) {
            $script:Controls['lblKinesisStatus'].Text = "Exists"
            $script:Controls['lblKinesisStatus'].ForeColor = [System.Drawing.Color]::DarkGreen
        } else {
            $script:Controls['lblKinesisStatus'].Text = "Will be created"
            $script:Controls['lblKinesisStatus'].ForeColor = [System.Drawing.Color]::FromArgb(180,130,0)
        }
    }
    $p.Controls.Add($btnCheckStream)

    # Auto-populate defaults when panel becomes visible
    $p.Add_VisibleChanged({
        if ($this.Visible -and $script:State.Prefix) {
            $pfx = $script:State.Prefix
            $map = @{
                'txtS3Iceberg' = "$pfx-iceberg-s3"
                'txtS3Landing' = "$pfx-landing-s3"
                'txtS3Config'  = "$pfx-config-s3"
                'txtKinesis'   = "$pfx-stream-kinesis"
            }
            foreach ($k in $map.Keys) {
                $ctl = $script:Controls[$k]
                if ($ctl -and (-not $ctl.Text -or $ctl.Text -match '-iceberg-s3$|-landing-s3$|-config-s3$|-stream-kinesis$')) {
                    $ctl.Text = $map[$k]
                }
            }
        }
    })

    return $p
}

#endregion

#region ── Google Cloud: Steps 1-4 ────────────────────────────
#
#  The Google Cloud page set. Steps 0 and 5 are shared with the AWS path;
#  these four exist because the resources they collect have no useful overlap
#  with VPC/security-group/IAM-role/Kinesis.
#
#  Open Lakehouse on Google Cloud is in Private Preview (opened 2 Sep 2026,
#  GA planned Q4 2026). Preview scope is CDC and SaaS sources, so there is no
#  streaming resource to collect - the AWS Kinesis slot is simply absent.

$script:GcpRegions = @(
    "us-central1", "us-east1", "us-east4", "us-west1",
    "europe-west1", "europe-west2", "europe-west3", "europe-west4",
    "asia-southeast1", "asia-northeast1"
)

function Sync-GcpState {
    $s = $script:State
    $s.Initials    = $script:Controls['txtGcpInitials'].Text.Trim().ToLower()
    $s.Workload    = $script:Controls['txtGcpWorkload'].Text.Trim().ToLower()
    $s.Environment = [string]$script:Controls['cboGcpEnv'].SelectedItem
    $s.Region      = [string]$script:Controls['cboGcpRegion'].SelectedItem
    Compute-Prefix
}

function Update-GcpDerivedNames {
    # Keep the generated names in step with the prefix, but never clobber a
    # value the user has typed over.
    Sync-GcpState
    $s = $script:State
    if (-not $s.Prefix) { return }

    $defaults = @{
        'txtGcpSubnetNew'  = "$($s.Prefix)-subnet"
        'txtGcpNetworkNew' = "$($s.Prefix)-vpc"
        'txtGcpFirewall'   = "$($s.Prefix)-allow-internal"
        'txtGcpRouter'     = "$($s.Prefix)-router"
        'txtGcpNat'        = "$($s.Prefix)-nat"
        'txtGcpKeyRing'    = "$($s.Prefix)-kr"
        'txtGcpKeyName'    = "$($s.Prefix)-key"
        'txtGcsTable'      = "$($s.Prefix)-table-gcs"
        'txtGcsLanding'    = "$($s.Prefix)-landing-gcs"
        'txtGcsConfig'     = "$($s.Prefix)-config-gcs"
        'txtGcsTfState'    = "$($s.Prefix)-tfstate-gcs"
    }
    foreach ($key in $defaults.Keys) {
        $ctl = $script:Controls[$key]
        if ($ctl -and -not $ctl.Tag) { $ctl.Text = $defaults[$key] }
    }

    # Service account IDs are capped at 30 characters.
    $mgmt = "$($s.Prefix)-mgmt"
    $node = "$($s.Prefix)-node"
    if ($mgmt.Length -gt 30) {
        $mgmt = "$($s.Initials)-$($s.Environment)-olh-mgmt"
        $node = "$($s.Initials)-$($s.Environment)-olh-node"
    }
    if ($script:Controls['txtGcpMgmtSa'] -and -not $script:Controls['txtGcpMgmtSa'].Tag) {
        $script:Controls['txtGcpMgmtSa'].Text = $mgmt
    }
    if ($script:Controls['txtGcpNodeSa'] -and -not $script:Controls['txtGcpNodeSa'].Tag) {
        $script:Controls['txtGcpNodeSa'].Text = $node
    }
}

function Connect-Gcp {
    $s = $script:State
    Write-LogCyan "  Authenticating to Google Cloud..."

    switch ($s.GcpAuthMethod) {
        "login" {
            Write-LogGray "  -> gcloud auth login"
            Start-Process -FilePath "gcloud" -ArgumentList "auth login" -Wait -NoNewWindow
        }
        "keyfile" {
            $kf = $script:Controls['txtGcpKeyFile'].Text.Trim()
            if (-not (Test-Path -LiteralPath $kf)) {
                Write-LogRed "  X   Key file not found: $kf"
                [System.Windows.Forms.MessageBox]::Show("Key file not found:`n$kf", "Authentication", 'OK', 'Warning') | Out-Null
                return
            }
            $s.GcpKeyFile = $kf
            $null = Invoke-GcloudCmd "gcloud auth activate-service-account --key-file=`"$kf`""
            # Terraform reads Application Default Credentials, which are a
            # separate store from the gcloud CLI credential.
            $env:GOOGLE_APPLICATION_CREDENTIALS = $kf
            Write-LogGray "  GOOGLE_APPLICATION_CREDENTIALS set for Terraform."
        }
    }

    $acct = Invoke-GcloudCmd "gcloud auth list --filter=status:ACTIVE --format=value(account)"
    if (-not $acct) {
        $s.GcpAuthenticated = $false
        $script:Controls['lblGcpAuthStatus'].Text = "Not authenticated"
        $script:Controls['lblGcpAuthStatus'].ForeColor = [System.Drawing.Color]::Red
        Write-LogRed "  X   No active gcloud credentials."
        return
    }
    $acct = ($acct -split "`n")[0].Trim()
    $s.GcpAccount = $acct
    $s.GcpAuthenticated = $true
    $script:Controls['lblGcpAuthStatus'].Text = "Authenticated: $acct"
    $script:Controls['lblGcpAuthStatus'].ForeColor = [System.Drawing.Color]::DarkGreen
    Write-LogGreen "  OK  Authenticated as $acct"

    Test-GcpAdc
    Load-GcpProjects
}

function Test-GcpAdc {
    # ADC is what the Terraform google provider uses. A run that authenticated
    # the CLI but not ADC fails later at plan time with a confusing error, so
    # surface it here instead.
    if ($env:GOOGLE_APPLICATION_CREDENTIALS) { return }
    $tok = Invoke-GcloudCmd "gcloud auth application-default print-access-token" -Silent
    if ($tok) { Write-LogGreen "  OK  Application Default Credentials present."; return }

    Write-LogYellow "  !!  No Application Default Credentials found."
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Terraform's Google provider needs Application Default Credentials, which are separate from the gcloud CLI login.`n`nRun 'gcloud auth application-default login' now?",
        "Application Default Credentials", 'YesNo', 'Question')
    if ($r -eq 'Yes') {
        Start-Process -FilePath "gcloud" -ArgumentList "auth application-default login" -Wait -NoNewWindow
        Write-LogGreen "  ADC login finished."
    } else {
        Write-LogYellow "      Skipped - terraform init/plan/apply will likely fail to authenticate."
    }
}

function Load-GcpProjects {
    $cbo = $script:Controls['cboGcpProject']
    $cbo.Items.Clear()
    Write-LogGray "  Loading projects..."
    $projects = Invoke-GcloudCmd "gcloud projects list --format=json" -AsJson
    if (-not $projects) { Write-LogYellow "  !!  No projects returned."; return }
    $script:State.GcpProjectList = @($projects)
    foreach ($proj in @($projects)) {
        $cbo.Items.Add("$($proj.projectId)  ($($proj.name))") | Out-Null
    }
    if ($cbo.Items.Count -gt 0) { $cbo.SelectedIndex = 0 }
    Write-LogGreen "  OK  $($cbo.Items.Count) project(s) found."
}

function Select-GcpProject {
    $cbo = $script:Controls['cboGcpProject']
    if ($cbo.SelectedIndex -lt 0) { return }
    $projId = (([string]$cbo.SelectedItem) -split '\s+')[0]
    $script:State.GcpProjectId = $projId

    $num = Invoke-GcloudCmd "gcloud projects describe $projId --format=value(projectNumber)"
    if ($num) {
        $script:State.GcpProjectNumber = $num.Trim()
        $script:Controls['lblGcpProjectNum'].Text = "Project number: $($num.Trim())"
        $null = Invoke-GcloudCmd "gcloud config set project $projId" -Silent
        Write-LogGreen "  OK  Project $projId (number $($num.Trim()))"
    } else {
        $script:Controls['lblGcpProjectNum'].Text = "Project number: could not read"
        Write-LogRed "  X   Cannot read project $projId."
    }
}

function Build-Step1Gcp {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'

    $p.Controls.Add((New-Label "Identity and Google Cloud Access" 20 10 500 24 -Bold -FontSize 11))

    # ── Naming ──
    $p.Controls.Add((New-Label "Owner initials" 20 44 110))
    $t = New-TextBox "txtGcpInitials" 135 42 90
    $t.Add_TextChanged({ Update-GcpDerivedNames })
    $p.Controls.Add($t)

    $p.Controls.Add((New-Label "Workload" 245 44 70))
    $t = New-TextBox "txtGcpWorkload" 320 42 80 "olh"
    $t.Add_TextChanged({ Update-GcpDerivedNames })
    $p.Controls.Add($t)

    $p.Controls.Add((New-Label "Environment" 420 44 80))
    $c = New-ComboBox "cboGcpEnv" 505 42 90 @("dev","uat","prod") "dev"
    $c.Add_SelectedIndexChanged({ Update-GcpDerivedNames })
    $p.Controls.Add($c)

    # ── Region and zones ──
    $p.Controls.Add((New-Label "Region" 20 76 110))
    $c = New-ComboBox "cboGcpRegion" 135 74 160 $script:GcpRegions "us-central1"
    $c.Add_SelectedIndexChanged({
        $reg = [string]$script:Controls['cboGcpRegion'].SelectedItem
        $z = $script:Controls['txtGcpZones']
        if ($z -and -not $z.Tag) { $z.Text = "$reg-a,$reg-b" }
        Update-GcpDerivedNames
    })
    $p.Controls.Add($c)

    $p.Controls.Add((New-Label "Zones" 315 76 50))
    $t = New-TextBox "txtGcpZones" 370 74 225 "us-central1-a,us-central1-b"
    $t.Add_TextChanged({ $this.Tag = "edited" })
    $p.Controls.Add($t)

    $lbl = New-Label "At least two, comma separated. The cluster spreads Spot VMs across them." 370 98 380
    $lbl.ForeColor = [System.Drawing.Color]::Gray
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $p.Controls.Add($lbl)

    $p.Controls.Add((New-Sep 20 122 720))

    # ── Authentication ──
    $p.Controls.Add((New-Label "Authentication" 20 132 200 22 -Bold))

    $rbCur = New-Object System.Windows.Forms.RadioButton
    $rbCur.Text = "Use current gcloud credentials"; $rbCur.Location = [System.Drawing.Point]::new(20, 158)
    $rbCur.Size = [System.Drawing.Size]::new(230, 22); $rbCur.Checked = $true
    $rbCur.Add_CheckedChanged({ if ($this.Checked) { $script:State.GcpAuthMethod = "current"; Show-HideGcpAuthRows } })
    $p.Controls.Add($rbCur)

    $rbLogin = New-Object System.Windows.Forms.RadioButton
    $rbLogin.Text = "gcloud auth login"; $rbLogin.Location = [System.Drawing.Point]::new(260, 158)
    $rbLogin.Size = [System.Drawing.Size]::new(160, 22)
    $rbLogin.Add_CheckedChanged({ if ($this.Checked) { $script:State.GcpAuthMethod = "login"; Show-HideGcpAuthRows } })
    $p.Controls.Add($rbLogin)

    $rbKey = New-Object System.Windows.Forms.RadioButton
    $rbKey.Text = "Service account key"; $rbKey.Location = [System.Drawing.Point]::new(430, 158)
    $rbKey.Size = [System.Drawing.Size]::new(170, 22)
    $rbKey.Add_CheckedChanged({ if ($this.Checked) { $script:State.GcpAuthMethod = "keyfile"; Show-HideGcpAuthRows } })
    $p.Controls.Add($rbKey)

    $lblKf = New-Label "Key file" 20 188 70
    $script:Controls['lblGcpKeyFile'] = $lblKf
    $lblKf.Visible = $false
    $p.Controls.Add($lblKf)

    $t = New-TextBox "txtGcpKeyFile" 95 186 430
    $t.Visible = $false
    $p.Controls.Add($t)

    $btnBrowse = New-Btn "Browse..." 535 185 90 25 {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "JSON key (*.json)|*.json|All files (*.*)|*.*"
        if ($dlg.ShowDialog() -eq 'OK') { $script:Controls['txtGcpKeyFile'].Text = $dlg.FileName }
    }
    $btnBrowse.Visible = $false
    $script:Controls['btnGcpBrowseKey'] = $btnBrowse
    $p.Controls.Add($btnBrowse)

    $btnConn = New-Btn "Connect" 20 218 110 30 { Connect-Gcp }
    $btnConn.BackColor = $script:Blue
    $btnConn.ForeColor = [System.Drawing.Color]::White
    $btnConn.FlatAppearance.BorderSize = 0
    $p.Controls.Add($btnConn)

    $lblSt = New-Label "Not authenticated" 145 224 480
    $lblSt.ForeColor = [System.Drawing.Color]::Gray
    $script:Controls['lblGcpAuthStatus'] = $lblSt
    $p.Controls.Add($lblSt)

    $p.Controls.Add((New-Sep 20 256 720))

    # ── Project ──
    $p.Controls.Add((New-Label "Project" 20 272 110 22 -Bold))
    $c = New-ComboBox "cboGcpProject" 135 270 330
    $c.Add_SelectedIndexChanged({ Select-GcpProject })
    $p.Controls.Add($c)

    $p.Controls.Add((New-Btn "Load Projects" 475 269 120 25 { Load-GcpProjects }))

    $lblNum = New-Label "Project number: -" 135 298 400
    $lblNum.ForeColor = [System.Drawing.Color]::Gray
    $script:Controls['lblGcpProjectNum'] = $lblNum
    $p.Controls.Add($lblNum)

    $lblPrev = New-Label "Private Preview: your tenant must be enrolled before a lakehouse cluster can be created." 20 328 720
    $lblPrev.ForeColor = [System.Drawing.Color]::FromArgb(180,130,0)
    $lblPrev.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $p.Controls.Add($lblPrev)

    return $p
}

function Show-HideGcpAuthRows {
    $show = ($script:State.GcpAuthMethod -eq "keyfile")
    foreach ($key in @('lblGcpKeyFile','txtGcpKeyFile','btnGcpBrowseKey')) {
        if ($script:Controls[$key]) { $script:Controls[$key].Visible = $show }
    }
}

function Load-GcpNetworks {
    $s = $script:State
    if (-not $s.GcpProjectId) {
        [System.Windows.Forms.MessageBox]::Show("Select a project on the Identity step first.", "Network", 'OK', 'Warning') | Out-Null
        return
    }
    $cbo = $script:Controls['cboGcpNetwork']
    $cbo.Items.Clear()
    Write-LogGray "  Loading VPC networks..."
    $nets = Invoke-GcloudCmd "gcloud compute networks list --project=$($s.GcpProjectId) --format=json" -AsJson
    if (-not $nets) { Write-LogYellow "  !!  No networks returned."; return }
    $s.NetworkList = @($nets)
    foreach ($n in @($nets)) { $cbo.Items.Add($n.name) | Out-Null }
    if ($cbo.Items.Count -gt 0) { $cbo.SelectedIndex = 0 }
    Write-LogGreen "  OK  $($cbo.Items.Count) network(s) found."
}

function Load-GcpSubnetworks {
    $s = $script:State
    $net = [string]$script:Controls['cboGcpNetwork'].SelectedItem
    if (-not $s.GcpProjectId -or -not $net) { return }
    $reg = [string]$script:Controls['cboGcpRegion'].SelectedItem
    $cbo = $script:Controls['cboGcpSubnet']
    $cbo.Items.Clear()
    Write-LogGray "  Loading subnetworks in $reg..."
    $subs = Invoke-GcloudCmd "gcloud compute networks subnets list --project=$($s.GcpProjectId) --regions=$reg --format=json" -AsJson
    if (-not $subs) { Write-LogYellow "  !!  No subnetworks returned."; return }
    $matching = @(@($subs) | Where-Object { $_.network -match "/$net$" })
    $s.SubnetworkList = $matching
    foreach ($sn in $matching) {
        $pga = if ($sn.privateIpGoogleAccess) { "PGA on" } else { "PGA OFF" }
        $cbo.Items.Add("$($sn.name)  $($sn.ipCidrRange)  $pga") | Out-Null
    }
    if ($cbo.Items.Count -gt 0) { $cbo.SelectedIndex = 0 }
    Write-LogGreen "  OK  $($cbo.Items.Count) subnetwork(s) in $net."
}

function Select-GcpSubnetwork {
    $cbo = $script:Controls['cboGcpSubnet']
    if ($cbo.SelectedIndex -lt 0) { return }
    $sn = $script:State.SubnetworkList[$cbo.SelectedIndex]
    $script:State.SubnetworkName = $sn.name
    $script:State.SubnetworkCidr = $sn.ipCidrRange
    $script:State.PrivateGoogleAccess = [bool]$sn.privateIpGoogleAccess
    $script:Controls['txtGcpSubnetCidr'].Text = $sn.ipCidrRange

    $lbl = $script:Controls['lblGcpPga']
    if ($script:State.PrivateGoogleAccess) {
        $lbl.Text = "Private Google Access: on"
        $lbl.ForeColor = [System.Drawing.Color]::DarkGreen
    } else {
        $lbl.Text = "Private Google Access: OFF - required by Open Lakehouse"
        $lbl.ForeColor = [System.Drawing.Color]::Red
    }
    $script:Controls['btnGcpEnablePga'].Visible = (-not $script:State.PrivateGoogleAccess)
}

function Enable-GcpPga {
    $s = $script:State
    $reg = [string]$script:Controls['cboGcpRegion'].SelectedItem
    Write-LogCyan "  Enabling Private Google Access on $($s.SubnetworkName)..."
    $r = Invoke-GcloudCmd "gcloud compute networks subnets update $($s.SubnetworkName) --project=$($s.GcpProjectId) --region=$reg --enable-private-ip-google-access"
    if ($null -ne $r) {
        $s.PrivateGoogleAccess = $true
        $script:Controls['lblGcpPga'].Text = "Private Google Access: on"
        $script:Controls['lblGcpPga'].ForeColor = [System.Drawing.Color]::DarkGreen
        $script:Controls['btnGcpEnablePga'].Visible = $false
        Write-LogGreen "  OK  Private Google Access enabled."
    } else {
        Write-LogRed "  X   Could not enable Private Google Access."
    }
}

function Build-Step2Gcp {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'

    $p.Controls.Add((New-Label "Network" 20 10 400 24 -Bold -FontSize 11))
    $lbl = New-Label "Private Google Access on the subnetwork is the Google Cloud counterpart of the S3 gateway endpoint." 20 36 720
    $lbl.ForeColor = [System.Drawing.Color]::Gray
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $p.Controls.Add($lbl)

    # ── VPC network ──
    $p.Controls.Add((New-Label "VPC network" 20 68 110))
    $c = New-ComboBox "cboGcpNetwork" 135 66 260
    $c.Add_SelectedIndexChanged({
        $script:State.NetworkName = [string]$script:Controls['cboGcpNetwork'].SelectedItem
        Load-GcpSubnetworks
    })
    $p.Controls.Add($c)
    $p.Controls.Add((New-Btn "Load" 405 65 70 25 { Load-GcpNetworks }))

    $chkNewNet = New-Object System.Windows.Forms.CheckBox
    $chkNewNet.Text = "Create new"; $chkNewNet.Location = [System.Drawing.Point]::new(485, 67)
    $chkNewNet.Size = [System.Drawing.Size]::new(95, 22)
    $chkNewNet.Add_CheckedChanged({
        $script:State.CreateNewVpc = $this.Checked
        $script:Controls['txtGcpNetworkNew'].Enabled = $this.Checked
        $script:Controls['cboGcpNetwork'].Enabled    = -not $this.Checked
    })
    $script:Controls['chkGcpNewNetwork'] = $chkNewNet
    $p.Controls.Add($chkNewNet)

    $t = New-TextBox "txtGcpNetworkNew" 585 66 160
    $t.Enabled = $false
    $t.Add_TextChanged({ $this.Tag = "edited" })
    $p.Controls.Add($t)

    # ── Subnetwork ──
    $p.Controls.Add((New-Label "Subnetwork" 20 102 110))
    $c = New-ComboBox "cboGcpSubnet" 135 100 260
    $c.Add_SelectedIndexChanged({ Select-GcpSubnetwork })
    $p.Controls.Add($c)
    $p.Controls.Add((New-Btn "Load" 405 99 70 25 { Load-GcpSubnetworks }))

    $chkNewSub = New-Object System.Windows.Forms.CheckBox
    $chkNewSub.Text = "Create new"; $chkNewSub.Location = [System.Drawing.Point]::new(485, 101)
    $chkNewSub.Size = [System.Drawing.Size]::new(95, 22)
    $chkNewSub.Add_CheckedChanged({
        $script:Controls['txtGcpSubnetNew'].Enabled = $this.Checked
        $script:Controls['cboGcpSubnet'].Enabled    = -not $this.Checked
    })
    $script:Controls['chkGcpNewSubnet'] = $chkNewSub
    $p.Controls.Add($chkNewSub)

    $t = New-TextBox "txtGcpSubnetNew" 585 100 160
    $t.Enabled = $false
    $t.Add_TextChanged({ $this.Tag = "edited" })
    $p.Controls.Add($t)

    $p.Controls.Add((New-Label "Subnetwork CIDR" 20 136 110))
    $p.Controls.Add((New-TextBox "txtGcpSubnetCidr" 135 134 160 "10.20.0.0/20"))

    $lblPga = New-Label "Private Google Access: -" 315 136 340
    $lblPga.ForeColor = [System.Drawing.Color]::Gray
    $script:Controls['lblGcpPga'] = $lblPga
    $p.Controls.Add($lblPga)

    $btnPga = New-Btn "Enable now" 660 133 90 25 { Enable-GcpPga }
    $btnPga.Visible = $false
    $script:Controls['btnGcpEnablePga'] = $btnPga
    $p.Controls.Add($btnPga)

    $p.Controls.Add((New-Sep 20 168 720))

    # ── Firewall ──
    $p.Controls.Add((New-Label "Firewall rule" 20 182 110 22 -Bold))
    $t = New-TextBox "txtGcpFirewall" 135 180 260
    $t.Add_TextChanged({ $this.Tag = "edited" })
    $p.Controls.Add($t)

    $lbl = New-Label "Ingress: all TCP/UDP/ICMP from the subnetwork CIDR. Egress is already allowed by the implied default rule." 20 206 720
    $lbl.ForeColor = [System.Drawing.Color]::Gray
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $p.Controls.Add($lbl)

    $p.Controls.Add((New-Sep 20 234 720))

    # ── Cloud NAT ──
    $p.Controls.Add((New-Label "Cloud Router" 20 248 110 22 -Bold))
    $t = New-TextBox "txtGcpRouter" 135 246 260
    $t.Add_TextChanged({ $this.Tag = "edited" })
    $p.Controls.Add($t)

    $p.Controls.Add((New-Label "Cloud NAT" 20 280 110))
    $t = New-TextBox "txtGcpNat" 135 278 260
    $t.Add_TextChanged({ $this.Tag = "edited" })
    $p.Controls.Add($t)

    $lbl = New-Label "Cluster nodes run without external IPs. Cloud NAT is how the agent reaches Qlik Talend Cloud - the counterpart of the AWS Internet Gateway." 20 306 720 32
    $lbl.ForeColor = [System.Drawing.Color]::Gray
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $p.Controls.Add($lbl)

    return $p
}

function Build-Step3Gcp {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'

    $p.Controls.Add((New-Label "Security, Identity and Tenant Binding" 20 10 500 24 -Bold -FontSize 11))

    # ── Cloud KMS ──
    $p.Controls.Add((New-Label "KMS key ring" 20 44 110))
    $t = New-TextBox "txtGcpKeyRing" 135 42 200
    $t.Add_TextChanged({ $this.Tag = "edited" })
    $p.Controls.Add($t)

    $p.Controls.Add((New-Label "KMS key" 350 44 70))
    $t = New-TextBox "txtGcpKeyName" 425 42 200
    $t.Add_TextChanged({ $this.Tag = "edited" })
    $p.Controls.Add($t)

    $lbl = New-Label "Symmetric CMEK for the lakehouse buckets. The Cloud Storage service agent is granted use of it automatically." 20 68 720
    $lbl.ForeColor = [System.Drawing.Color]::Gray
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $p.Controls.Add($lbl)

    $p.Controls.Add((New-Sep 20 92 720))

    # ── Service accounts ──
    $p.Controls.Add((New-Label "Service accounts" 20 102 200 22 -Bold))

    $p.Controls.Add((New-Label "Management" 20 130 110))
    $t = New-TextBox "txtGcpMgmtSa" 135 128 200
    $t.Add_TextChanged({ $this.Tag = "edited" })
    $p.Controls.Add($t)

    $p.Controls.Add((New-Label "Node" 350 130 70))
    $t = New-TextBox "txtGcpNodeSa" 425 128 200
    $t.Add_TextChanged({ $this.Tag = "edited" })
    $p.Controls.Add($t)

    $lbl = New-Label "Two accounts on purpose: QTC impersonates the management account from outside the project, while the node account is attached to the VMs and holds the data-plane grants." 20 154 720 32
    $lbl.ForeColor = [System.Drawing.Color]::Gray
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $p.Controls.Add($lbl)

    $p.Controls.Add((New-Sep 20 192 720))

    # ── QTC tenant binding ──
    $p.Controls.Add((New-Label "Qlik Talend Cloud tenant binding" 20 202 300 22 -Bold))

    $p.Controls.Add((New-Label "Tenant ID" 20 232 110))
    $p.Controls.Add((New-TextBox "txtQtcTenantId" 135 230 260))

    $lbl = New-Label "From Administration > Network integrations" 405 232 300
    $lbl.ForeColor = [System.Drawing.Color]::Gray
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $p.Controls.Add($lbl)

    $p.Controls.Add((New-Label "Auth method" 20 264 110))
    $c = New-ComboBox "cboQtcAuthMethod" 135 262 260 @("workload_identity","preauthorized_sa") "workload_identity"
    $c.Add_SelectedIndexChanged({
        $m = [string]$script:Controls['cboQtcAuthMethod'].SelectedItem
        $script:State.QtcAuthMethod = $m
        $isWif = ($m -eq "workload_identity")
        $script:Controls['txtQtcIssuer'].Enabled = $isWif
        $script:Controls['lblQtcIssuer'].Enabled = $isWif
    })
    $p.Controls.Add($c)

    $lblIss = New-Label "OIDC issuer" 20 296 110
    $script:Controls['lblQtcIssuer'] = $lblIss
    $p.Controls.Add($lblIss)
    $p.Controls.Add((New-TextBox "txtQtcIssuer" 135 294 400 "https://auth.qlik.com/oauth/token"))

    $lblWarn = New-Label "Assumption: Qlik has not published the GCP authentication model for the Private Preview. Workload Identity Federation mirrors the assume-role + ExternalId pattern used on AWS. Confirm against your onboarding pack." 20 322 720 44
    $lblWarn.ForeColor = [System.Drawing.Color]::FromArgb(180,130,0)
    $lblWarn.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $p.Controls.Add($lblWarn)

    return $p
}

function Build-Step4Gcp {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'

    $p.Controls.Add((New-Label "Cloud Storage" 20 10 400 24 -Bold -FontSize 11))
    $lbl = New-Label "All three lakehouse buckets are created with the CMEK above, uniform bucket-level access, and public access prevention." 20 36 720
    $lbl.ForeColor = [System.Drawing.Color]::Gray
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $p.Controls.Add($lbl)

    $y = 70
    foreach ($row in @(
        @('Table storage', 'txtGcsTable',   'Iceberg table data'),
        @('Landing',       'txtGcsLanding', 'Incoming data staged before conversion'),
        @('Config',        'txtGcsConfig',  'Cluster runtime configuration'),
        @('Terraform state','txtGcsTfState','Remote state for the GCP module (Google-managed encryption)')
    )) {
        $p.Controls.Add((New-Label $row[0] 20 ($y + 2) 110))
        $t = New-TextBox $row[1] 135 $y 280
        $t.Add_TextChanged({ $this.Tag = "edited" })
        $p.Controls.Add($t)
        $hint = New-Label $row[2] 425 ($y + 3) 330
        $hint.ForeColor = [System.Drawing.Color]::Gray
        $hint.Font = New-Object System.Drawing.Font("Segoe UI", 8)
        $p.Controls.Add($hint)
        $y += 34
    }

    $p.Controls.Add((New-Sep 20 ($y + 8) 720))

    $lblStream = New-Label "Streaming: none in this release." 20 ($y + 22) 300 22 -Bold
    $p.Controls.Add($lblStream)

    $lbl = New-Label "The Private Preview covers CDC and SaaS sources only, so there is no stream resource to provision - this is where the AWS path creates a Kinesis stream. Streaming on Google Cloud will be Kafka and GCS, arriving later in the preview." 20 ($y + 46) 720 46
    $lbl.ForeColor = [System.Drawing.Color]::Gray
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $p.Controls.Add($lbl)

    return $p
}

#endregion

#region ── Step 5: Review & Deploy ────────────────────────────

function Build-Step5 {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'

    $p.Controls.Add((New-Label "Review and Deploy" 20 5 720 28 -Bold -FontSize 11))

    # Summary RichTextBox
    $rtbSum = New-Object System.Windows.Forms.RichTextBox
    $rtbSum.Name     = "rtbSummary"
    $rtbSum.Location = [System.Drawing.Point]::new(20, 35)
    $rtbSum.Size     = [System.Drawing.Size]::new(500, 270)
    $rtbSum.ReadOnly = $true
    $rtbSum.Font     = New-Object System.Drawing.Font("Consolas", 8.5)
    $rtbSum.BackColor = [System.Drawing.Color]::FromArgb(248, 253, 249)
    $script:Controls['rtbSummary'] = $rtbSum
    $p.Controls.Add($rtbSum)

    # Tag Compliance Panel
    $dgv = New-Object System.Windows.Forms.DataGridView
    $dgv.Name = "dgvTags"
    $dgv.Location = [System.Drawing.Point]::new(530, 35)
    $dgv.Size     = [System.Drawing.Size]::new(230, 180)
    $dgv.ReadOnly = $true
    $dgv.AllowUserToAddRows    = $false
    $dgv.AllowUserToDeleteRows = $false
    $dgv.RowHeadersVisible     = $false
    $dgv.AutoSizeColumnsMode   = 'Fill'
    $dgv.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $dgv.Columns.Add("Key", "Tag Key")       | Out-Null
    $dgv.Columns.Add("Value", "Value")       | Out-Null
    $dgv.Columns.Add("Status", "Status")     | Out-Null
    $dgv.Columns["Key"].FillWeight   = 35
    $dgv.Columns["Value"].FillWeight = 40
    $dgv.Columns["Status"].FillWeight = 25
    $script:Controls['dgvTags'] = $dgv
    $p.Controls.Add($dgv)

    # Deploy Button
    $btnDeploy = New-Btn "Deploy" 530 230 230 40 {
        if ($script:State.Deploying) { return }
        $mode = $script:State.Mode
        if ($mode -eq "Teardown") {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "This will PERMANENTLY DESTROY all resources for prefix: $($script:State.Prefix)`n`nAre you sure?",
                "Confirm Teardown", 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
        }
        $script:State.Deploying = $true
        $script:Controls['btnDeploy'].Enabled = $false
        $script:Controls['btnDeploy'].Text = "Deploying..."
        $script:Controls['prgDeploy'].Visible = $true
        $script:Controls['btnBack'].Enabled = $false
        $script:Controls['btnNext'].Enabled = $false

        Start-Deploy
    }
    $btnDeploy.BackColor = $script:Blue
    $btnDeploy.ForeColor = [System.Drawing.Color]::White
    $btnDeploy.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnDeploy.FlatStyle = 'Flat'
    $btnDeploy.FlatAppearance.BorderSize = 0
    $script:Controls['btnDeploy'] = $btnDeploy
    $p.Controls.Add($btnDeploy)

    # Open Report
    $btnReport = New-Btn "Open Report" 530 280 110 28 {
        $rpt = Join-Path $script:ScriptDir "deploy-report.html"
        if (Test-Path $rpt) { Start-Process $rpt }
    }
    $btnReport.Visible = $false
    $script:Controls['btnOpenReport'] = $btnReport
    $p.Controls.Add($btnReport)

    # Open QTC File
    $btnQtc = New-Btn "Open QTC Ref" 650 280 110 28 {
        $qtc = Join-Path $script:ScriptDir "qlik-network-integration.txt"
        if (Test-Path $qtc) { Start-Process "notepad.exe" -ArgumentList $qtc }
    }
    $btnQtc.Visible = $false
    $script:Controls['btnOpenQtc'] = $btnQtc
    $p.Controls.Add($btnQtc)

    # Progress Bar
    $prg = New-Object System.Windows.Forms.ProgressBar
    $prg.Name = "prgDeploy"; $prg.Location = [System.Drawing.Point]::new(20, 320)
    $prg.Size = [System.Drawing.Size]::new(720, 22); $prg.Minimum = 0; $prg.Maximum = 100
    $prg.Visible = $false
    $script:Controls['prgDeploy'] = $prg
    $p.Controls.Add($prg)

    # Status Label
    $lblSt = New-Label "" 20 348 720
    $lblSt.ForeColor = [System.Drawing.Color]::Gray
    $script:Controls['lblDeployStatus'] = $lblSt
    $p.Controls.Add($lblSt)

    # Populate summary when visible
    $p.Add_VisibleChanged({
        if ($this.Visible) { Populate-Summary }
    })

    return $p
}

function Populate-Summary {
    if ($script:State.Cloud -eq "gcp") { Populate-SummaryGcp; return }
    $s = $script:State
    $rtb = $script:Controls['rtbSummary']
    $rtb.Clear()

    $modeLabel = switch ($s.Mode) {
        "Deploy"   { "LIVE DEPLOY" }
        "DryRun"   { "DRY-RUN (no changes)" }
        "Drift"    { "DRIFT CHECK" }
        "Teardown" { "TEARDOWN" }
    }

    $vpcNote   = if ($s.CreateNewVpc) { "[NEW - CIDR: $($script:Controls['txtNewVpcCidr'].Text)]" } else { "[existing]" }
    $sgNote    = if ($s.CreateNewSg)  { "[NEW]" } else { "[existing]" }
    $kmsNote   = if ($s.CreateNewKms) { "[NEW]" } else { "[existing]" }

    $subLines = ($s.SubnetAzPairs | ForEach-Object {
        $tag = if ($_.IsNew) { " [NEW]" } else { "" }
        "    $($_.Subnet)  AZ:$($_.AZ)$tag"
    }) -join "`r`n"

    $text = @"
  Mode:           $modeLabel
  Prefix:         $($s.Prefix)
  Region:         $($s.Region)
  Account:        $($s.AccountId)
  Date:           $($s.CreateDate)

  --- Network ---
  VPC:            $($s.VpcId) $vpcNote
  Subnets ($($s.SubnetAzPairs.Count)):
$subLines
  Security Group: $($s.SgId) $sgNote

  --- Security ---
  KMS Key:        $($s.KmsKeyArn) $kmsNote
  Management role:  $($s.Prefix)-mgmt-role-iam   [trusted by Qlik, ExternalId required]
  Node role:        $($s.Prefix)-ec2-role-iam    [EC2 trust, data-plane policy from Terraform]
  Instance Profile: $($s.Prefix)-instance-profile
  Qlik proxy:       $($s.QlikProxyRoleArn)
  QTC ExternalId:   $(if ($s.QtcExternalId) { "set" } else { "NOT SET" })

  --- Storage ---
  S3 Iceberg:     $($script:Controls['txtS3Iceberg'].Text)
  S3 Landing:     $($script:Controls['txtS3Landing'].Text)
  S3 Config:      $($script:Controls['txtS3Config'].Text)
  Kinesis Stream: $($script:Controls['txtKinesis'].Text)  (1 shard)
"@
    $rtb.Text = $text

    # Populate tag grid
    $dgv = $script:Controls['dgvTags']
    $dgv.Rows.Clear()
    $tags = [ordered]@{
        Owner       = $s.Initials
        Environment = $s.Environment
        Workload    = "qlik-olh"
        Application = "open-lakehouse"
        CreateDate  = $s.CreateDate
        ManagedBy   = "script"
    }
    foreach ($k in $tags.Keys) {
        $v = $tags[$k]
        $status = if ($v) { "OK" } else { "MISSING" }
        $idx = $dgv.Rows.Add($k, $v, $status)
        if ($status -eq "OK") {
            $dgv.Rows[$idx].Cells[2].Style.ForeColor = [System.Drawing.Color]::DarkGreen
        } else {
            $dgv.Rows[$idx].Cells[2].Style.ForeColor = [System.Drawing.Color]::Red
        }
    }

    # Update deploy button label
    $btn = $script:Controls['btnDeploy']
    $btn.Text = switch ($s.Mode) {
        "Deploy"   { "Deploy" }
        "DryRun"   { "Dry Run" }
        "Drift"    { "Run Drift Check" }
        "Teardown" { "TEARDOWN" }
    }
    if ($s.Mode -eq "Teardown") { $btn.BackColor = [System.Drawing.Color]::DarkRed }
    elseif ($s.Mode -eq "DryRun") { $btn.BackColor = $script:QlikTeal }
    else { $btn.BackColor = $script:QlikGreen }
}

#endregion

#region ── Deploy Logic ───────────────────────────────────────

function Update-Progress {
    param([int]$Pct, [string]$Status)
    $script:Controls['prgDeploy'].Value = [Math]::Min($Pct, 100)
    $script:Controls['lblDeployStatus'].Text = $Status
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-TerraformFlow {
    # init -> plan -> (ask) -> apply, all in the given root module directory.
    # Shared by both clouds; only the backend arguments differ.
    param([string]$WorkDir, [string]$InitArgs)

    function Start-Tf {
        param([string]$Arguments, [string]$Dir)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = "terraform"
        $psi.Arguments = $Arguments
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $psi.WorkingDirectory = $Dir
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        return [PSCustomObject]@{ Code = $proc.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
    }

    Write-LogGray "  -> terraform $InitArgs"
    $r1 = Start-Tf -Arguments $InitArgs -Dir $WorkDir
    if ($r1.Code -ne 0) {
        Write-LogRed "  X  terraform init failed (exit $($r1.Code))"
        if ($r1.Err) { Write-LogRed ("  " + (($r1.Err.Trim() -split "`n" | Select-Object -First 8) -join "`n  ")) }
        return
    }
    Write-LogGreen "  OK  terraform init complete"

    Write-LogGray "  -> terraform plan"
    $r2 = Start-Tf -Arguments "plan -var-file=`"terraform.tfvars`" -out=`"tfplan`"" -Dir $WorkDir
    if ($r2.Code -ne 0) {
        Write-LogRed "  X  terraform plan failed (exit $($r2.Code))"
        if ($r2.Err) { Write-LogRed ("  " + (($r2.Err.Trim() -split "`n" | Select-Object -First 12) -join "`n  ")) }
        return
    }
    Write-LogGreen "  OK  terraform plan saved to tfplan"

    $ans = [System.Windows.Forms.MessageBox]::Show("Terraform plan is ready. Apply now?", "Terraform Apply", 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }

    Write-LogGray "  -> terraform apply tfplan"
    $r3 = Start-Tf -Arguments "apply `"tfplan`"" -Dir $WorkDir
    if ($r3.Code -eq 0) {
        Write-LogGreen "  OK  terraform apply complete!"
        $r4 = Start-Tf -Arguments "output qtc_summary" -Dir $WorkDir
        if ($r4.Code -eq 0 -and $r4.Out) {
            Write-LogCyan "`n  QTC integration values:"
            Write-LogGray $r4.Out.TrimEnd()
        }
    } else {
        Write-LogRed "  X  terraform apply failed (exit $($r3.Code))"
        if ($r3.Err) { Write-LogRed ("  " + (($r3.Err.Trim() -split "`n" | Select-Object -First 8) -join "`n  ")) }
    }
}

function Start-Deploy {
    if ($script:State.Cloud -eq "gcp") { Start-DeployGcp; return }

    $s       = $script:State
    $DryRun  = ($s.Mode -eq "DryRun")
    $PREFIX  = $s.Prefix
    $acctId  = $s.AccountId

    Write-LogCyan "`n  ============================================================"
    Write-LogCyan "  Deployment Starting  [$($s.Mode)]  Prefix: $PREFIX"
    Write-LogCyan "  ============================================================`n"

    # ── Drift Mode ──
    if ($s.Mode -eq "Drift") {
        Update-Progress 10 "Running drift detection..."
        Write-Log "  Running drift detection for $PREFIX..." -Bold $true

        $tfvarsPath = Join-Path (Get-TerraformDir) "terraform.tfvars"
        if (-not (Test-Path $tfvarsPath)) {
            Write-LogRed "  X  terraform.tfvars not found. Run a deployment first."
            Deploy-Complete; return
        }
        $tfContent = Get-Content $tfvarsPath -Raw
        function Local:Get-TfVal { param([string]$Key, [string]$Content)
            if ($Content -match "$Key\s*=\s*`"([^`"]+)`"") { return $Matches[1] }; return "(not set)"
        }

        # Each resource is looked up BY the value in tfvars, not by a
        # prefix-derived Name tag: a resource the user named differently is not
        # drift. A failed lookup means the resource is gone (or unreadable).
        Update-Progress 30 "Checking VPC..."
        $tfVpc = Local:Get-TfVal "vpc_id" $tfContent
        $liveVpc = if ($tfVpc -ne "(not set)") { Invoke-AwsCmd "aws ec2 describe-vpcs --region $($s.Region) --vpc-ids $tfVpc --query `"Vpcs[0].VpcId`" --output text" -Silent } else { $null }
        $st = if ($liveVpc -and $liveVpc -eq $tfVpc) { "MATCH" } else { "NOT_FOUND" }
        if ($st -eq "MATCH") { Write-LogGreen "  VPC:  $tfVpc  ->  $st" } else { Write-LogRed "  VPC:  Expected=$tfVpc  Live=$(if ($liveVpc) { $liveVpc } else { '(absent)' })  ->  $st" }

        Update-Progress 50 "Checking Security Group..."
        $tfSg = Local:Get-TfVal "security_group_id" $tfContent
        $liveSg = if ($tfSg -ne "(not set)") { Invoke-AwsCmd "aws ec2 describe-security-groups --region $($s.Region) --group-ids $tfSg --query `"SecurityGroups[0].GroupId`" --output text" -Silent } else { $null }
        $st = if ($liveSg -and $liveSg -eq $tfSg) { "MATCH" } else { "NOT_FOUND" }
        if ($st -eq "MATCH") { Write-LogGreen "  SG:   $tfSg  ->  $st" } else { Write-LogRed "  SG:   Expected=$tfSg  Live=$(if ($liveSg) { $liveSg } else { '(absent)' })  ->  $st" }

        Update-Progress 70 "Checking Kinesis..."
        $tfKin = Local:Get-TfVal "kinesis_stream_name" $tfContent
        $liveKin = if ($tfKin -ne "(not set)") { Invoke-AwsCmd "aws kinesis describe-stream-summary --stream-name `"$tfKin`" --region $($s.Region) --query `"StreamDescriptionSummary.StreamName`" --output text" -Silent } else { $null }
        $st = if ($liveKin -and $liveKin -eq $tfKin) { "MATCH" } else { "NOT_FOUND" }
        if ($st -eq "MATCH") { Write-LogGreen "  Kinesis: $tfKin  ->  $st" } else { Write-LogRed "  Kinesis: Expected=$tfKin  Live=$(if ($liveKin) { $liveKin } else { '(absent)' })  ->  $st" }

        Update-Progress 100 "Drift detection complete"
        Write-LogGreen "`n  OK  Drift detection complete."
        Deploy-Complete; return
    }

    # ── Teardown Mode ──
    if ($s.Mode -eq "Teardown") {
        Update-Progress 5 "Starting teardown..."
        Write-LogRed "  !! TEARDOWN: Destroying resources for $PREFIX"

        # Read the ACTUAL resource names from terraform.tfvars when present --
        # the user may have customized them during deployment; recomputing
        # defaults from $PREFIX would miss (orphan) renamed resources.
        $twTfDir  = Get-TerraformDir
        $twTfvars = Join-Path $twTfDir "terraform.tfvars"
        $twIceberg = "$PREFIX-iceberg-s3"; $twKinesis = "$PREFIX-stream-kinesis"
        $twLanding = "$PREFIX-landing-s3"; $twConfig  = "$PREFIX-config-s3"
        if (Test-Path $twTfvars) {
            $twContent = Get-Content $twTfvars -Raw
            if ($twContent -match 's3_bucket_name\s*=\s*"([^"]+)"')      { $twIceberg = $Matches[1] }
            if ($twContent -match 's3_landing_bucket\s*=\s*"([^"]+)"')   { $twLanding = $Matches[1] }
            if ($twContent -match 's3_config_bucket\s*=\s*"([^"]+)"')    { $twConfig  = $Matches[1] }
            if ($twContent -match 'kinesis_stream_name\s*=\s*"([^"]+)"') { $twKinesis = $Matches[1] }
        } else {
            Write-LogYellow "  !!  terraform.tfvars not found -- using default names derived from prefix."
        }

        # Process.Start throws on a WorkingDirectory that does not exist.
        if ($script:State.TerraformOk -and -not (Test-Path -LiteralPath $twTfDir)) {
            Write-LogYellow "  !!  $twTfDir not found -- skipping terraform destroy."
        } elseif ($script:State.TerraformOk) {
            Update-Progress 15 "Running terraform destroy..."
            Write-LogGray "  -> terraform destroy -auto-approve -var-file=terraform.tfvars"
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "terraform"; $psi.Arguments = "destroy -auto-approve -var-file=terraform.tfvars"
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.WorkingDirectory = $twTfDir
            $proc = [System.Diagnostics.Process]::Start($psi)
            # Drain both pipes asynchronously BEFORE WaitForExit -- terraform is
            # verbose enough to fill the pipe buffer and deadlock otherwise.
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
            $proc.WaitForExit()
            if ($proc.ExitCode -ne 0) {
                $tfErr = $errTask.Result
                Write-LogRed "  X  terraform destroy failed (exit $($proc.ExitCode))"
                if ($tfErr) { Write-LogRed ("  " + (($tfErr.Trim() -split "`n" | Select-Object -First 8) -join "`n  ")) }
            } else {
                Write-LogGreen "  OK  terraform destroy complete"
            }
            $null = $outTask.Result
        }

        Update-Progress 40 "Removing S3 buckets..."
        foreach ($bucket in @($twIceberg, $twLanding, $twConfig)) {
            Write-LogGray "  -> Emptying & deleting: $bucket"
            Invoke-AwsCmd "aws s3 rm s3://$bucket --recursive --region $($s.Region)" -Silent
            $bktDel = Invoke-AwsCmd "aws s3api delete-bucket --bucket $bucket --region $($s.Region)" -Silent
            if ($null -ne $bktDel) { Write-LogGreen "  OK  Removed: $bucket" }
            else { Write-LogRed "  X   Could not delete bucket: $bucket (absent, not empty, or access denied)" }
        }

        Update-Progress 60 "Removing Kinesis stream..."
        $kinDel = Invoke-AwsCmd "aws kinesis delete-stream --stream-name $twKinesis --region $($s.Region)" -Silent
        if ($null -ne $kinDel) { Write-LogGreen "  OK  Kinesis stream removed ($twKinesis)" }
        else { Write-LogRed "  X   Could not delete Kinesis stream: $twKinesis (absent or access denied)" }

        Update-Progress 80 "Removing IAM resources..."
        Invoke-AwsCmd "aws iam remove-role-from-instance-profile --instance-profile-name $PREFIX-instance-profile --role-name $PREFIX-ec2-role-iam" -Silent
        Invoke-AwsCmd "aws iam delete-instance-profile --instance-profile-name $PREFIX-instance-profile" -Silent
        Write-LogGreen "  OK  Instance profile removed"

        Update-Progress 100 "Teardown complete"
        Write-LogGreen "`n  OK  Teardown complete for: $PREFIX"
        Deploy-Complete; return
    }

    # ── Normal Deploy / DryRun ──
    $step = 0; $totalSteps = 14

    # Step 1: Pre-flight permission check
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Pre-flight: permission check..."
    Write-Log "  -- Pre-flight Checks --" -Bold $true
    $services = [ordered]@{
        "EC2"     = @("ec2:CreateVpc","ec2:CreateSubnet","ec2:CreateSecurityGroup","ec2:DescribeVpcs")
        "S3"      = @("s3:CreateBucket","s3:PutBucketPolicy","s3:PutEncryptionConfiguration")
        "IAM"     = @("iam:CreateRole","iam:CreateInstanceProfile","iam:AttachRolePolicy")
        "KMS"     = @("kms:CreateKey","kms:CreateAlias","kms:TagResource")
        "Kinesis" = @("kinesis:CreateStream","kinesis:DescribeStream")
        "Glue"    = @("glue:CreateDatabase","glue:GetDatabase")
        "STS"     = @("sts:GetCallerIdentity")
    }
    # simulate-principal-policy only evaluates an IAM role/user as the policy
    # source. A verified caller is usually an STS session ARN
    # (arn:aws:sts::<acct>:assumed-role/<RoleName>/<session>), which has to be
    # rewritten to the underlying role first.
    $policySourceArn = ""
    if     ($s.CallerArn -match '^arn:([^:]+):sts::(\d+):assumed-role/([^/]+)/') {
        $simRole = $Matches[3]
        $policySourceArn = "arn:$($Matches[1]):iam::$($Matches[2]):role/$simRole"
        # The session ARN drops the role's IAM path (SSO roles live under
        # /aws-reserved/sso.amazonaws.com/), so prefer the ARN IAM reports.
        $simRoleArn = Invoke-AwsCmd "aws iam get-role --role-name $simRole --query Role.Arn --output text" -Silent
        if ($simRoleArn) { $policySourceArn = $simRoleArn }
    }
    elseif ($s.CallerArn -match '^arn:[^:]+:iam::\d+:(role|user)/')              { $policySourceArn = $s.CallerArn }
    if (-not $policySourceArn) {
        Write-LogYellow "  !!  Permissions NOT verified: no IAM role/user ARN for caller '$($s.CallerArn)'"
    } else {
        Write-LogGray "  Simulating required actions against $policySourceArn"
        foreach ($svc in $services.Keys) {
            $sim = Invoke-AwsCmd "aws iam simulate-principal-policy --policy-source-arn `"$policySourceArn`" --action-names $($services[$svc] -join ' ') --output json" -AsJson -Silent
            if (-not $sim -or -not $sim.EvaluationResults) {
                # Never a green OK for something that was not measured.
                Write-LogYellow "  !!  $svc permissions could not be verified (simulate call failed)"
                continue
            }
            $denied = @($sim.EvaluationResults | Where-Object { $_.EvalDecision -ne "allowed" })
            if ($denied.Count -eq 0) { Write-LogGreen "  OK  $svc permissions allowed" }
            else { Write-LogRed "  X   $svc denied: $(($denied | ForEach-Object { "$($_.EvalActionName) ($($_.EvalDecision))" }) -join ', ')" }
        }
    }

    # Step 2: CloudTrail check
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Pre-flight: CloudTrail check..."
    $ct = Invoke-AwsCmd "aws cloudtrail get-trail-status --name default --region $($s.Region) --query IsLogging --output text" -Silent
    if ($ct -eq "true") { Write-LogGreen "  OK  CloudTrail: logging active" }
    else                { Write-LogYellow "  !!  CloudTrail: check skipped (non-blocking)" }

    # Step 3: Duplicate guard
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Pre-flight: duplicate resource guard..."
    Write-Log "`n  -- Duplicate Resource Guard --" -Bold $true
    $existBkts = Invoke-AwsCmd "aws s3api list-buckets --query `"Buckets[?starts_with(Name,'$PREFIX')].Name`" --output text" -Silent
    if ($existBkts) { Write-LogYellow "  !!  S3 buckets exist with prefix: $existBkts" }
    else            { Write-LogGreen "  OK  No S3 buckets with prefix $PREFIX" }

    # Step 4: VPC
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Network: VPC..."
    Write-Log "`n  -- Network --" -Bold $true
    $VPC_ID   = $s.VpcId
    $VPC_CIDR = $s.VpcCidr
    if ($s.CreateNewVpc) {
        $VPC_CIDR = $script:Controls['txtNewVpcCidr'].Text
        if ($DryRun) {
            $VPC_ID = "vpc-DRYRUN"; Write-LogYellow "  [DRY-RUN] Would create VPC with CIDR $VPC_CIDR"
        } else {
            Write-LogGray "  Creating VPC with CIDR $VPC_CIDR..."
            $newVpc = Invoke-AwsCmd "aws ec2 create-vpc --cidr-block $VPC_CIDR --region $($s.Region) --tag-specifications `"$(Build-TagSpec 'vpc' "$PREFIX-vpc")`" --output json" -AsJson
            if ($newVpc) {
                $VPC_ID = $newVpc.Vpc.VpcId
                Invoke-AwsCmd "aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames --region $($s.Region)" -Silent
                Invoke-AwsCmd "aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support --region $($s.Region)" -Silent
                Write-LogGreen "  OK  Created VPC: $VPC_ID ($VPC_CIDR)"
            } else { Write-LogRed "  X  Failed to create VPC" }
        }
    } else {
        Write-LogGreen "  OK  Using VPC: $VPC_ID ($VPC_CIDR)"
    }

    # Step 5: Subnets
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Network: Subnets..."
    $subnetAzPairs = [System.Collections.ArrayList]::new()
    foreach ($pair in $s.SubnetAzPairs) {
        if ($pair.IsNew) {
            if ($DryRun) {
                $subnetAzPairs.Add([PSCustomObject]@{ Subnet="subnet-DRYRUN-$($pair.AZ)"; AZ=$pair.AZ }) | Out-Null
                Write-LogYellow "  [DRY-RUN] Would create subnet $($pair.CIDR) in $($pair.AZ)"
            } else {
                $ns = Invoke-AwsCmd "aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $($pair.CIDR) --availability-zone $($pair.AZ) --region $($s.Region) --tag-specifications `"$(Build-TagSpec 'subnet' "$PREFIX-subnet")`" --output json" -AsJson
                if ($ns) {
                    $subId = $ns.Subnet.SubnetId
                    $subnetAzPairs.Add([PSCustomObject]@{ Subnet=$subId; AZ=$pair.AZ }) | Out-Null
                    Write-LogGreen "  OK  Created subnet: $subId AZ:$($pair.AZ)"
                }
            }
        } else {
            $subnetAzPairs.Add([PSCustomObject]@{ Subnet=$pair.Subnet; AZ=$pair.AZ }) | Out-Null
            Write-LogGreen "  OK  Using subnet: $($pair.Subnet) AZ:$($pair.AZ)"
        }
    }

    # Step 5b: Subnet prerequisite check
    #
    # terraform/aws/main.tf refuses to plan unless every cluster subnet
    # auto-assigns public IPs (null_resource.olh_prerequisites). Check it here,
    # where the selection is known, instead of sending the user into a plan
    # that fails. Mirrors the bash wizard's Subnet Prerequisite Check.
    if (-not $DryRun) {
        $nonPublic = @()
        foreach ($snPair in $subnetAzPairs) {
            $mapPub = Invoke-AwsCmd "aws ec2 describe-subnets --subnet-ids $($snPair.Subnet) --region $($s.Region) --query `"Subnets[0].MapPublicIpOnLaunch`" --output text" -Silent
            if ($mapPub -ne "True") { $nonPublic += $snPair.Subnet }
        }
        if ($nonPublic.Count -gt 0) {
            Write-LogYellow "  !!  These subnets do not auto-assign public IPs: $($nonPublic -join ', ')"
            Write-LogGray   "      OLH cluster subnets must be public. Terraform will refuse to plan otherwise."
            $fixSn = [System.Windows.Forms.MessageBox]::Show(
                "These subnets do not auto-assign public IPs:`n`n$($nonPublic -join "`n")`n`nOpen Lakehouse requires public cluster subnets; terraform plan will refuse otherwise.`n`nEnable auto-assign public IP on them now?",
                "Subnet Prerequisite", 'YesNo', 'Warning')
            if ($fixSn -eq 'Yes') {
                foreach ($sn in $nonPublic) {
                    $upd = Invoke-AwsCmd "aws ec2 modify-subnet-attribute --subnet-id $sn --region $($s.Region) --map-public-ip-on-launch" -Silent
                    if ($null -ne $upd) { Write-LogGreen "  OK  $sn updated." } else { Write-LogRed "  X   Could not update $sn." }
                }
            }
        } else {
            Write-LogGreen "  OK  All selected subnets auto-assign public IPs."
        }
    }

    # Step 6: Security Group
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Network: Security Group..."
    $SG_ID = $s.SgId
    if ($s.CreateNewSg) {
        if ($DryRun) {
            $SG_ID = "sg-DRYRUN"; Write-LogYellow "  [DRY-RUN] Would create security group $PREFIX-sg"
        } else {
            Write-LogGray "  Creating $PREFIX-sg (inbound all TCP from the VPC CIDR)..."
            $sgOut = Invoke-AwsCmd "aws ec2 create-security-group --group-name `"$PREFIX-sg`" --description `"Qlik OLH $PREFIX`" --vpc-id $VPC_ID --region $($s.Region) --tag-specifications `"$(Build-TagSpec 'security-group' "$PREFIX-sg")`" --output json" -AsJson
            if ($sgOut) {
                $SG_ID = $sgOut.GroupId
                # Open Lakehouse requires inbound All TCP from the VPC CIDR so
                # cluster nodes and the network integration agent can reach each
                # other. Outbound needs no rule: AWS attaches an allow-all egress
                # rule to every new security group, which is what OLH asks for.
                Invoke-AwsCmd "aws ec2 authorize-security-group-ingress --group-id $SG_ID --region $($s.Region) --ip-permissions `"IpProtocol=tcp,FromPort=0,ToPort=65535,IpRanges=[{CidrIp=$VPC_CIDR}]`"" -Silent
                Write-LogGreen "  OK  Created SG: $SG_ID  (ingress all TCP from $VPC_CIDR, egress all)"
            }
        }
    } else {
        Write-LogGreen "  OK  Using SG: $SG_ID"
    }

    # Step 7: KMS Key
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Security: KMS Key..."
    Write-Log "`n  -- Security and Encryption --" -Bold $true
    $KMS_KEY_ARN = $s.KmsKeyArn
    if ($s.CreateNewKms) {
        if ($DryRun) {
            $KMS_KEY_ARN = "arn:aws:kms:$($s.Region):${acctId}:key/DRYRUN"
            Write-LogYellow "  [DRY-RUN] Would create KMS key alias/$PREFIX-kms"
        } else {
            Write-LogGray "  Creating KMS symmetric key..."
            $kmsOut = Invoke-AwsCmd "aws kms create-key --region $($s.Region) --description `"Qlik OLH $PREFIX`" --key-usage ENCRYPT_DECRYPT --tags `"TagKey=Name,TagValue=$PREFIX-kms`" `"TagKey=Owner,TagValue=$($s.Initials)`" `"TagKey=Environment,TagValue=$($s.Environment)`" `"TagKey=CreateDate,TagValue=$($s.CreateDate)`" `"TagKey=Workload,TagValue=qlik-olh`" --output json" -AsJson
            if ($kmsOut) {
                $keyId = $kmsOut.KeyMetadata.KeyId
                Invoke-AwsCmd "aws kms create-alias --alias-name `"alias/$PREFIX-kms`" --target-key-id $keyId --region $($s.Region)" -Silent
                $KMS_KEY_ARN = "arn:aws:kms:$($s.Region):${acctId}:key/$keyId"
                Write-LogGreen "  OK  Created KMS: $KMS_KEY_ARN"
            }
        }
    } else {
        Write-LogGreen "  OK  Using KMS: $KMS_KEY_ARN"
    }

    # Step 8: IAM roles
    #
    # Two roles, and it matters which is which. The management role is assumed
    # by Qlik from outside the account and carries the ExternalId condition;
    # the node role is assumed by EC2, goes into the instance profile, and
    # receives the S3/Kinesis/KMS/Glue policy from Terraform. Earlier versions
    # created only the EC2 role and reported it as mgmt_role_arn, which left
    # QTC with nothing it could assume.
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Security: IAM management role..."
    $MGMT_ROLE_NAME = "$PREFIX-mgmt-role-iam"
    $NODE_ROLE_NAME = "$PREFIX-ec2-role-iam"

    $mgmtTrust = @{
        Version = "2012-10-17"
        Statement = @(@{
            Effect    = "Allow"
            Principal = @{ AWS = $s.QlikProxyRoleArn }
            Action    = "sts:AssumeRole"
            Condition = @{ StringEquals = @{ "sts:ExternalId" = $s.QtcExternalId } }
        })
    } | ConvertTo-Json -Depth 8 -Compress

    $mgmtTrustFile = Join-Path $env:TEMP "olh-mgmt-trust-$PID.json"
    $nodeTrustFile = Join-Path $env:TEMP "olh-node-trust-$PID.json"
    $nodeTrust = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

    if ($DryRun) {
        $MGMT_ROLE_ARN = "arn:aws:iam::${acctId}:role/$MGMT_ROLE_NAME-DRYRUN"
        Write-LogYellow "  [DRY-RUN] Would create management role $MGMT_ROLE_NAME"
        Write-LogGray   "            trusting $($s.QlikProxyRoleArn) with sts:ExternalId"
    } else {
        # Passed as a file:// argument: the policy contains quotes and braces
        # that do not survive being spliced into a command line.
        Set-Content -Path $mgmtTrustFile -Value $mgmtTrust -Encoding ASCII
        $existing = Invoke-AwsCmd "aws iam get-role --role-name `"$MGMT_ROLE_NAME`" --output json" -AsJson -Silent
        if ($existing) {
            Write-LogGreen "  OK  Management role exists: $MGMT_ROLE_NAME"
            Invoke-AwsCmd "aws iam update-assume-role-policy --role-name `"$MGMT_ROLE_NAME`" --policy-document file://$mgmtTrustFile" -Silent
            Write-LogGray  "      Trust policy refreshed with the ExternalId you entered."
        } else {
            Write-LogGray "  Creating management role $MGMT_ROLE_NAME..."
            Invoke-AwsCmd "aws iam create-role --role-name `"$MGMT_ROLE_NAME`" --description `"Qlik Talend Cloud management role for $PREFIX`" --assume-role-policy-document file://$mgmtTrustFile --tags `"Key=Owner,Value=$($s.Initials)`" `"Key=Environment,Value=$($s.Environment)`" `"Key=Workload,Value=qlik-olh`" `"Key=CreateDate,Value=$($s.CreateDate)`" `"Key=ManagedBy,Value=script`"" -Silent
            Write-LogGreen "  OK  Created: $MGMT_ROLE_NAME"
            Write-LogGray  "      Trust: $($s.QlikProxyRoleArn) with sts:ExternalId"
        }
        Remove-Item $mgmtTrustFile -Force -ErrorAction SilentlyContinue
        $MGMT_ROLE_ARN = "arn:aws:iam::${acctId}:role/$MGMT_ROLE_NAME"
    }
    $s.MgmtRoleArn = $MGMT_ROLE_ARN

    # Step 9: EC2 node role
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Security: EC2 node role..."
    if ($DryRun) {
        $NODE_ROLE_ARN = "arn:aws:iam::${acctId}:role/$NODE_ROLE_NAME-DRYRUN"
        Write-LogYellow "  [DRY-RUN] Would create node role $NODE_ROLE_NAME"
    } else {
        $existingNode = Invoke-AwsCmd "aws iam get-role --role-name `"$NODE_ROLE_NAME`" --output json" -AsJson -Silent
        if ($existingNode) {
            Write-LogGreen "  OK  Node role exists: $NODE_ROLE_NAME"
        } else {
            Set-Content -Path $nodeTrustFile -Value $nodeTrust -Encoding ASCII
            Write-LogGray "  Creating node role $NODE_ROLE_NAME..."
            Invoke-AwsCmd "aws iam create-role --role-name `"$NODE_ROLE_NAME`" --description `"Qlik Open Lakehouse EC2 node role for $PREFIX`" --assume-role-policy-document file://$nodeTrustFile --tags `"Key=Owner,Value=$($s.Initials)`" `"Key=Environment,Value=$($s.Environment)`" `"Key=Workload,Value=qlik-olh`" `"Key=CreateDate,Value=$($s.CreateDate)`" `"Key=ManagedBy,Value=script`"" -Silent
            Invoke-AwsCmd "aws iam attach-role-policy --role-name `"$NODE_ROLE_NAME`" --policy-arn `"arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore`"" -Silent
            Remove-Item $nodeTrustFile -Force -ErrorAction SilentlyContinue
            Write-LogGreen "  OK  Created: $NODE_ROLE_NAME (SSM Core attached)"
            Write-LogGray  "      Terraform adds the S3/Kinesis/KMS/Glue data-plane policy."
        }
        $NODE_ROLE_ARN = "arn:aws:iam::${acctId}:role/$NODE_ROLE_NAME"
    }
    $s.NodeRoleArn = $NODE_ROLE_ARN

    # Step 9b: Instance profile, holding the node role
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Security: Instance Profile..."
    $PROFILE_NAME = "$PREFIX-instance-profile"
    if ($DryRun) {
        $INSTANCE_PROFILE_ARN = "arn:aws:iam::${acctId}:instance-profile/$PROFILE_NAME-DRYRUN"
        Write-LogYellow "  [DRY-RUN] Would create instance profile $PROFILE_NAME"
    } else {
        $prof = Invoke-AwsCmd "aws iam get-instance-profile --instance-profile-name `"$PROFILE_NAME`" --output json" -AsJson -Silent
        if ($prof) {
            Write-LogGreen "  OK  Instance profile exists: $PROFILE_NAME"
            $held = @($prof.InstanceProfile.Roles | ForEach-Object { $_.RoleName })
            if ($held -notcontains $NODE_ROLE_NAME) {
                if ($held.Count -eq 0) {
                    Write-LogYellow "  !!  It holds no role - attaching $NODE_ROLE_NAME"
                    Invoke-AwsCmd "aws iam add-role-to-instance-profile --instance-profile-name `"$PROFILE_NAME`" --role-name `"$NODE_ROLE_NAME`"" -Silent
                } else {
                    Write-LogYellow "  !!  It holds '$($held -join ', ')', not $NODE_ROLE_NAME."
                }
            }
        } else {
            Write-LogGray "  Creating instance profile $PROFILE_NAME..."
            Invoke-AwsCmd "aws iam create-instance-profile --instance-profile-name `"$PROFILE_NAME`" --tags `"Key=Owner,Value=$($s.Initials)`" `"Key=Environment,Value=$($s.Environment)`" `"Key=CreateDate,Value=$($s.CreateDate)`"" -Silent
            Invoke-AwsCmd "aws iam add-role-to-instance-profile --instance-profile-name `"$PROFILE_NAME`" --role-name `"$NODE_ROLE_NAME`"" -Silent
            Write-LogGreen "  OK  Created: $PROFILE_NAME (role $NODE_ROLE_NAME)"
        }
        $INSTANCE_PROFILE_ARN = "arn:aws:iam::${acctId}:instance-profile/$PROFILE_NAME"
    }
    $s.InstanceProfileArn = $INSTANCE_PROFILE_ARN

    # Step 9c: S3 gateway VPC endpoint
    #
    # An OLH network prerequisite. AWS allows one gateway endpoint per VPC per
    # service, so find an existing one and hand it to Terraform; otherwise
    # leave the tfvars entry empty and let Terraform create it.
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Network: S3 gateway endpoint..."
    $S3_VPCE_ID = ""
    if (-not $DryRun) {
        $vpceRaw = Invoke-AwsCmd "aws ec2 describe-vpc-endpoints --region $($s.Region) --filters `"Name=vpc-id,Values=$VPC_ID`" `"Name=service-name,Values=com.amazonaws.$($s.Region).s3`" --output json" -AsJson -Silent
        if ($vpceRaw) {
            $gw = @($vpceRaw.VpcEndpoints | Where-Object { $_.VpcEndpointType -eq "Gateway" })
            if ($gw.Count -gt 0) { $S3_VPCE_ID = $gw[0].VpcEndpointId }
        }
    }
    if ($S3_VPCE_ID) {
        Write-LogGreen "  OK  Existing S3 gateway endpoint: $S3_VPCE_ID (Terraform will reuse it)"
    } else {
        Write-LogYellow "  !!  No S3 gateway endpoint in this VPC - Terraform will create one."
    }
    $s.S3GatewayEndpoint = $S3_VPCE_ID

    # Step 10: S3 Buckets
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Storage: S3 Buckets..."
    Write-Log "`n  -- Storage and Streaming --" -Bold $true
    $S3_ICEBERG = $script:Controls['txtS3Iceberg'].Text
    $S3_LANDING = $script:Controls['txtS3Landing'].Text
    $S3_CONFIG  = $script:Controls['txtS3Config'].Text
    $TFSTATE_BUCKET = "$PREFIX-tfstate-s3"

    # The CLI never saw this as inline JSON: Windows argument parsing strips the
    # embedded quotes, so the rule set arrived invalid and the -Silent call failed
    # unnoticed, leaving every bucket without default encryption. Pass it as
    # file://, like the IAM trust policies. KMSMasterKeyID pins the buckets to the
    # OLH CMK that Terraform grants the node role envelope-encryption on;
    # BucketKeyEnabled keeps KMS request volume down on Iceberg traffic.
    $sseFile  = Join-Path $env:TEMP "olh-s3-sse-$PID.json"
    $sseRules = if ($KMS_KEY_ARN) {
        "{`"Rules`":[{`"ApplyServerSideEncryptionByDefault`":{`"SSEAlgorithm`":`"aws:kms`",`"KMSMasterKeyID`":`"$KMS_KEY_ARN`"},`"BucketKeyEnabled`":true}]}"
    } else {
        "{`"Rules`":[{`"ApplyServerSideEncryptionByDefault`":{`"SSEAlgorithm`":`"aws:kms`"},`"BucketKeyEnabled`":true}]}"
    }
    if (-not $DryRun) { Set-Content -Path $sseFile -Value $sseRules -Encoding ASCII }

    foreach ($bn in @($S3_ICEBERG, $S3_LANDING, $S3_CONFIG, $TFSTATE_BUCKET)) {
        $exists = Invoke-AwsCmd "aws s3api head-bucket --bucket $bn --region $($s.Region)" -Silent
        if ($exists -ne $null) {
            Write-LogGreen "  OK  Bucket exists: $bn"
        } else {
            if ($DryRun) {
                Write-LogYellow "  [DRY-RUN] Would create bucket: $bn"
            } else {
                Write-LogGray "  Creating bucket: $bn"
                if ($s.Region -eq "us-east-1") {
                    $mk = Invoke-AwsCmd "aws s3api create-bucket --bucket $bn --region $($s.Region)" -Silent
                } else {
                    $mk = Invoke-AwsCmd "aws s3api create-bucket --bucket $bn --region $($s.Region) --create-bucket-configuration `"LocationConstraint=$($s.Region)`"" -Silent
                }
                if ($null -eq $mk) {
                    # Invoke-AwsCmd returns $null only on a non-zero exit. Claiming
                    # success here puts a bucket that does not exist into tfvars.
                    Write-LogRed "  X   Failed to create bucket: $bn"
                    continue
                }
                $encOk = $null -ne (Invoke-AwsCmd "aws s3api put-bucket-encryption --bucket $bn --server-side-encryption-configuration `"file://$sseFile`"" -Silent)
                Invoke-AwsCmd "aws s3api put-public-access-block --bucket $bn --public-access-block-configuration `"BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true`"" -Silent
                $tagOk = $null -ne (Invoke-AwsCmd "aws s3api put-bucket-tagging --bucket $bn --tagging `"TagSet=[{Key=Owner,Value=$($s.Initials)},{Key=Environment,Value=$($s.Environment)},{Key=Workload,Value=qlik-olh},{Key=CreateDate,Value=$($s.CreateDate)},{Key=ManagedBy,Value=script}]`"" -Silent)
                if ($bn -eq $TFSTATE_BUCKET) {
                    # Terraform state benefits from versioning; the lakehouse buckets do not.
                    Invoke-AwsCmd "aws s3api put-bucket-versioning --bucket $TFSTATE_BUCKET --versioning-configuration Status=Enabled" -Silent
                }
                $encNote = if ($KMS_KEY_ARN) { "CMK-encrypted" } else { "KMS-encrypted" }
                if ($encOk -and $tagOk) {
                    Write-LogGreen "  OK  Created: $bn ($encNote, tagged)"
                } else {
                    $missing = @()
                    if (-not $encOk) { $missing += "encryption NOT applied" }
                    if (-not $tagOk) { $missing += "tags NOT applied" }
                    Write-LogYellow "  !!  Created: $bn ($($missing -join '; '))"
                }
            }
        }
    }
    Remove-Item $sseFile -Force -ErrorAction SilentlyContinue

    # Step 11: Kinesis Stream
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Storage: Kinesis Stream..."
    $KINESIS_NAME = $script:Controls['txtKinesis'].Text
    $kinExists = Invoke-AwsCmd "aws kinesis describe-stream-summary --stream-name $KINESIS_NAME --region $($s.Region)" -Silent
    if ($kinExists) {
        Write-LogGreen "  OK  Kinesis stream exists: $KINESIS_NAME"
    } else {
        if ($DryRun) {
            Write-LogYellow "  [DRY-RUN] Would create Kinesis stream: $KINESIS_NAME"
        } else {
            Invoke-AwsCmd "aws kinesis create-stream --stream-name $KINESIS_NAME --shard-count 1 --region $($s.Region)" -Silent
            Invoke-AwsCmd "aws kinesis add-tags-to-stream --stream-name $KINESIS_NAME --region $($s.Region) --tags `"Owner=$($s.Initials),Environment=$($s.Environment),Workload=qlik-olh,CreateDate=$($s.CreateDate)`"" -Silent
            Write-LogGreen "  OK  Created: $KINESIS_NAME"
        }
    }

    # Step 12: Tag Compliance
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Verifying tag compliance..."
    Write-Log "`n  -- Tag Compliance --" -Bold $true
    $requiredTags = [ordered]@{
        Owner=$s.Initials; Environment=$s.Environment; Workload="qlik-olh"
        Application="open-lakehouse"; CreateDate=$s.CreateDate; ManagedBy="script"
    }
    $allCompliant = $true
    foreach ($k in $requiredTags.Keys) {
        $v = $requiredTags[$k]
        if ($v) { Write-LogGreen "  OK  $k = $v" }
        else    { Write-LogRed   "  X   $k = (empty)"; $allCompliant = $false }
    }
    if (-not $allCompliant) { Write-LogRed "  X  Tag compliance failed!" }
    else                    { Write-LogGreen "  OK  All tags compliant" }

    # Step 13: Output Files
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Writing output files..."
    Write-Log "`n  -- Output Files --" -Bold $true

    $subnetBlock = ($subnetAzPairs | ForEach-Object {
        "    Subnet: $($_.Subnet)   AZ: $($_.AZ)"
    }) -join "`n"

    $modeComment = if ($DryRun) { "DRY-RUN" } else { "LIVE" }
    $tfDir = Get-TerraformDir
    if (-not (Test-Path -LiteralPath $tfDir)) { New-Item -ItemType Directory -Path $tfDir -Force | Out-Null }
    $tfvarsPath = Join-Path $tfDir "terraform.tfvars"
    $subnetIdsHcl = "[" + (($subnetAzPairs | ForEach-Object { '"' + $_.Subnet + '"' }) -join ", ") + "]"

    @"
# Generated by qlik_deploy_olh_gui.ps1
# $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# Mode: $modeComment

# Contains your QTC ExternalId. Keep it out of source control.

initials               = "$($s.Initials)"
workload               = "$($s.Workload)"
env                    = "$($s.Environment)"
aws_region             = "$($s.Region)"
aws_account_id         = "$acctId"
tfstate_bucket         = "$TFSTATE_BUCKET"

vpc_id                 = "$VPC_ID"
vpc_cidr               = "$VPC_CIDR"
subnet_ids             = $subnetIdsHcl
security_group_id      = "$SG_ID"
s3_gateway_endpoint_id = "$S3_VPCE_ID"

kms_key_arn            = "$KMS_KEY_ARN"
mgmt_role_arn          = "$MGMT_ROLE_ARN"
node_role_arn          = "$NODE_ROLE_ARN"
instance_profile_arn   = "$INSTANCE_PROFILE_ARN"
qlik_proxy_role_arn    = "$($s.QlikProxyRoleArn)"
qtc_external_id        = "$($s.QtcExternalId)"

s3_bucket_name         = "$S3_ICEBERG"
s3_landing_bucket      = "$S3_LANDING"
s3_config_bucket       = "$S3_CONFIG"
kinesis_stream_name    = "$KINESIS_NAME"
kinesis_shards         = 1

# Tags
tag_owner      = "$($s.Initials)"
tag_env        = "$($s.Environment)"
tag_workload   = "qlik-olh"
tag_createdate = "$($s.CreateDate)"
"@ | Set-Content -Path $tfvarsPath -Encoding UTF8
    Write-LogGreen "  OK  terraform.tfvars"

    # QTC Reference file
    $qtcFile = Join-Path $script:ScriptDir "qlik-network-integration.txt"
    $sep55 = "-" * 55
    $eq64  = "=" * 64

    @"
$eq64
  Qlik Open Lakehouse -- QTC Network Integration Reference
  Generated  : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Prefix     : $PREFIX
  Mode       : $modeComment
$eq64

$sep55
  ENTITY                         VALUE
$sep55
  AWS Account ID               : $acctId
  VPC ID                       : $VPC_ID
  CIDR Range of VPC            : $VPC_CIDR

  Subnet / Availability Zone pairs:
$subnetBlock

  Symmetric KMS Key ARN        : $KMS_KEY_ARN
  S3 Bucket Name               : $S3_ICEBERG
  Kinesis Stream Name          : $KINESIS_NAME
  Security Group ID            : $SG_ID
  S3 Gateway VPC Endpoint      : $(if ($S3_VPCE_ID) { $S3_VPCE_ID } else { "created by Terraform" })
  Management Role ARN          : $MGMT_ROLE_ARN
  Node Role ARN                : $NODE_ROLE_ARN
  Instance Profile ARN         : $INSTANCE_PROFILE_ARN
$sep55

  APPLIED TAGS
$sep55
  Owner         : $($s.Initials)
  Environment   : $($s.Environment)
  Workload      : qlik-olh
  Application   : open-lakehouse
  CreateDate    : $($s.CreateDate)
  ManagedBy     : script
$sep55

  GENERATED RESOURCE NAMES
$sep55
  S3 Iceberg    : $S3_ICEBERG
  S3 Landing    : $S3_LANDING
  S3 Config     : $S3_CONFIG
  IAM Role      : $PREFIX-ec2-role-iam
  Glue Database : $($s.Initials)_$($s.Workload)_$($s.Environment)_db_glue
  SSM Path      : /$($s.Initials)/$($s.Workload)/$($s.Environment)
$sep55
"@ | Set-Content -Path $qtcFile -Encoding UTF8
    Write-LogGreen "  OK  qlik-network-integration.txt"

    # HTML Report
    $rptFile = Join-Path $script:ScriptDir "deploy-report.html"
    $snHtml = ($subnetAzPairs | ForEach-Object {
        "<div class='v'>Subnet: $($_.Subnet) / AZ: $($_.AZ)</div>"
    }) -join ""

    @"
<!DOCTYPE html><html><head><meta charset="UTF-8">
<title>Qlik OLH Deploy Report - $PREFIX</title>
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
.ok{background:#dafbe1;color:#116329}
.warn{background:#fff8c5;color:#9a6700}
</style></head><body>
<h1>Qlik Open Lakehouse -- Deployment Report
  <small>Prefix: $PREFIX | Region: $($s.Region) | $(Get-Date)</small>
</h1>
<div class="section"><h2>Status</h2><div class="chips">
  <span class="chip warn">Prerequisites Provisioned - Terraform Pending</span>
  <span class="chip $(if ($allCompliant) { 'ok' } else { 'warn' })">$(if ($allCompliant) { 'Tags Compliant' } else { 'Tags Incomplete' })</span>
  <span class="chip $(if ($DryRun) { 'warn' } else { 'ok' })">$(if ($DryRun) { 'Dry-Run Mode' } else { 'Live Mode' })</span>
</div></div>
<div class="section"><h2>Network</h2><div class="grid">
  <div class="k">VPC ID</div><div class="v">$VPC_ID</div>
  <div class="k">VPC CIDR</div><div class="v">$VPC_CIDR</div>
  <div class="k">Security Group</div><div class="v">$SG_ID</div>
  <div class="k">Subnets / AZs</div>$snHtml
</div></div>
<div class="section"><h2>Security and Encryption</h2><div class="grid">
  <div class="k">KMS Key ARN</div><div class="v">$KMS_KEY_ARN</div>
  <div class="k">Management Role</div><div class="v">$MGMT_ROLE_ARN</div>
  <div class="k">Instance Profile</div><div class="v">$INSTANCE_PROFILE_ARN</div>
</div></div>
<div class="section"><h2>Storage and Streaming</h2><div class="grid">
  <div class="k">S3 Iceberg</div><div class="v">$S3_ICEBERG</div>
  <div class="k">S3 Landing</div><div class="v">$S3_LANDING</div>
  <div class="k">S3 Config</div><div class="v">$S3_CONFIG</div>
  <div class="k">Kinesis Stream</div><div class="v">$KINESIS_NAME</div>
</div></div>
<div class="section"><h2>Applied Tags</h2><div class="tags">
  <span class="tag">Owner: $($s.Initials)</span>
  <span class="tag">Environment: $($s.Environment)</span>
  <span class="tag">Workload: qlik-olh</span>
  <span class="tag">Application: open-lakehouse</span>
  <span class="tag">CreateDate: $($s.CreateDate)</span>
  <span class="tag">ManagedBy: script</span>
</div></div>
<div class="section"><h2>Generated Names</h2><div class="grid">
  <div class="k">IAM Role</div><div class="v">$PREFIX-ec2-role-iam</div>
  <div class="k">Glue Database</div><div class="v">$($s.Initials)_$($s.Workload)_$($s.Environment)_db_glue</div>
  <div class="k">SSM Path</div><div class="v">/$($s.Initials)/$($s.Workload)/$($s.Environment)</div>
  <div class="k">TF State Bucket</div><div class="v">$TFSTATE_BUCKET</div>
</div></div>
</body></html>
"@ | Set-Content -Path $rptFile -Encoding UTF8
    Write-LogGreen "  OK  deploy-report.html"

    # Step 14: Terraform
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Terraform..."
    if (-not $DryRun -and $script:State.TerraformOk) {
        Write-Log "`n  -- Terraform ($tfDir) --" -Bold $true
        $initArgs = "init -reconfigure -backend-config=`"bucket=$TFSTATE_BUCKET`" -backend-config=`"key=qlik-lakehouse/terraform.tfstate`" -backend-config=`"region=$($s.Region)`""
        Invoke-TerraformFlow -WorkDir $tfDir -InitArgs $initArgs
    } elseif ($DryRun) {
        Write-LogYellow "  [DRY-RUN] Terraform steps skipped"
    } else {
        Write-LogYellow "  !!  Terraform not available - skipping init/plan/apply"
    }

    Update-Progress 100 "Complete!"
    Write-LogCyan "`n  ============================================================"
    Write-LogCyan "  Deployment Complete!"
    Write-LogCyan "  ============================================================"
    Write-LogGreen "  Output files: terraform.tfvars, qlik-network-integration.txt, deploy-report.html"

    Deploy-Complete
}

function Deploy-Complete {
    $script:State.Deploying = $false
    $script:Controls['btnDeploy'].Enabled = $true
    $script:Controls['btnDeploy'].Text = "Done"
    $script:Controls['btnBack'].Enabled = $true
    $script:Controls['btnNext'].Enabled = $true
    $script:Controls['btnOpenReport'].Visible = $true
    $script:Controls['btnOpenQtc'].Visible = $true
}

#endregion

#region ── Google Cloud deployment ────────────────────────────

function Populate-SummaryGcp {
    $s = $script:State
    $rtb = $script:Controls['rtbSummary']
    $rtb.Clear()

    $modeLabel = switch ($s.Mode) {
        "Deploy"   { "LIVE DEPLOY" }
        "DryRun"   { "DRY-RUN (no changes)" }
        default    { "LIVE DEPLOY" }
    }

    $text = @"
  Cloud:          Google Cloud  (Private Preview)
  Mode:           $modeLabel
  Prefix:         $($s.Prefix)
  Project:        $($s.GcpProjectId)  (number $($s.GcpProjectNumber))
  Region:         $($s.Region)
  Zones:          $($s.GcpZones -join ', ')
  Date:           $($s.CreateDate)

  --- Network ---
  VPC network:    $($s.NetworkName)
  Subnetwork:     $($s.SubnetworkName)  $($s.SubnetworkCidr)
  Private Google Access: $(if ($s.PrivateGoogleAccess) { 'on' } else { 'OFF - will be enabled' })
  Firewall rule:  $($s.FirewallRule)
  Cloud NAT:      $($s.NatName) via $($s.NatRouter)

  --- Security ---
  KMS key:        $($s.GcpKmsKeyId)
  Management SA:  $($s.MgmtServiceAccount)
  Node SA:        $($s.NodeServiceAccount)
  QTC tenant:     $($s.QtcTenantId)
  QTC auth:       $($s.QtcAuthMethod)

  --- Storage ---
  Table storage:  $($s.GcsTable)
  Landing:        $($s.GcsLanding)
  Config:         $($s.GcsConfig)
  TF state:       $($s.GcsTfState)
  Streaming:      none - Private Preview covers CDC and SaaS sources

  --- Created by Terraform ---
  BigLake catalog:  $($s.Initials)_$($s.Workload)_$($s.Environment)_catalog
  BigLake database: $($s.Initials)_$($s.Workload)_$($s.Environment)_db
  BigQuery mirror:  $($s.Initials)_$($s.Workload)_$($s.Environment)_mirror
"@
    $rtb.Text = $text

    $dgv = $script:Controls['dgvTags']
    $dgv.Rows.Clear()
    $labels = [ordered]@{
        owner       = $s.Initials
        environment = $s.Environment
        workload    = "qlik-olh"
        application = "open-lakehouse"
        createdate  = $s.CreateDate
        managedby   = "script"
    }
    foreach ($k in $labels.Keys) {
        $v = $labels[$k]
        $status = if ($v) { "Compliant" } else { "Missing" }
        $dgv.Rows.Add($k, $v, $status) | Out-Null
    }
}

function Start-DeployGcp {
    $s = $script:State
    $s.Deploying = $true
    $DryRun = ($s.Mode -eq "DryRun")
    $PREFIX = $s.Prefix
    $proj   = $s.GcpProjectId
    $region = $s.Region

    $script:Controls['rtbLog'].Clear()
    Write-LogCyan "  Qlik Open Lakehouse - Google Cloud deployment"
    Write-LogYellow "  Private Preview (opened 2 Sep 2026). Scope: CDC and SaaS sources."
    Write-Log ""

    $totalSteps = 11
    $step = 0

    # ── APIs ──
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Enabling required APIs..."
    Write-Log "  -- Required APIs --" -Bold $true
    $apis = @(
        "compute.googleapis.com", "storage.googleapis.com", "cloudkms.googleapis.com",
        "secretmanager.googleapis.com", "biglake.googleapis.com", "bigquery.googleapis.com",
        "iam.googleapis.com", "iamcredentials.googleapis.com", "sts.googleapis.com"
    )
    if ($DryRun) {
        Write-LogYellow "  [DRY-RUN] Would enable $($apis.Count) APIs"
    } else {
        $r = Invoke-GcloudCmd "gcloud services enable $($apis -join ' ') --project=$proj"
        if ($null -ne $r) { Write-LogGreen "  OK  $($apis.Count) API(s) enabled" }
        else { Write-LogYellow "  !!  Could not enable every API - you may lack serviceusage.services.enable" }
    }

    # ── VPC network ──
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Network: VPC..."
    Write-Log "`n  -- Network --" -Bold $true
    $net = $s.NetworkName
    if ($script:Controls['chkGcpNewNetwork'].Checked) {
        if ($DryRun) {
            Write-LogYellow "  [DRY-RUN] Would create network $net"
        } else {
            $exists = Invoke-GcloudCmd "gcloud compute networks describe $net --project=$proj --format=json" -AsJson -Silent
            if ($exists) {
                Write-LogGreen "  OK  Network already exists: $net"
            } else {
                Invoke-GcloudCmd "gcloud compute networks create $net --project=$proj --subnet-mode=custom" -Silent
                Write-LogGreen "  OK  Created network: $net"
            }
        }
    } else {
        Write-LogGreen "  OK  Using network: $net"
    }

    # ── Subnetwork ──
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Network: Subnetwork..."
    $sub  = $s.SubnetworkName
    $cidr = $s.SubnetworkCidr
    if ($script:Controls['chkGcpNewSubnet'].Checked) {
        if ($DryRun) {
            Write-LogYellow "  [DRY-RUN] Would create subnetwork $sub ($cidr) with Private Google Access"
        } else {
            $exists = Invoke-GcloudCmd "gcloud compute networks subnets describe $sub --project=$proj --region=$region --format=json" -AsJson -Silent
            if ($exists) {
                Write-LogGreen "  OK  Subnetwork already exists: $sub"
            } else {
                Invoke-GcloudCmd "gcloud compute networks subnets create $sub --project=$proj --network=$net --region=$region --range=$cidr --enable-private-ip-google-access" -Silent
                Write-LogGreen "  OK  Created subnetwork: $sub ($cidr, Private Google Access on)"
            }
            $s.PrivateGoogleAccess = $true
        }
    } else {
        Write-LogGreen "  OK  Using subnetwork: $sub ($cidr)"
        # Private Google Access is the counterpart of the S3 gateway endpoint
        # on AWS. Terraform refuses to plan without it, so fix it here.
        if (-not $s.PrivateGoogleAccess -and -not $DryRun) {
            Write-LogYellow "  !!  Private Google Access is off - enabling"
            $r = Invoke-GcloudCmd "gcloud compute networks subnets update $sub --project=$proj --region=$region --enable-private-ip-google-access" -Silent
            if ($null -ne $r) {
                $s.PrivateGoogleAccess = $true
                Write-LogGreen "  OK  Private Google Access enabled"
            } else {
                Write-LogRed "  X   Could not enable Private Google Access - Terraform will refuse to plan"
            }
        }
    }

    # ── Cloud Router and NAT ──
    # Cluster nodes run without external IPs. Private Google Access covers
    # Google APIs; Cloud NAT is what lets the agent reach Qlik Talend Cloud,
    # which is the role the Internet Gateway plays on AWS.
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Network: Cloud NAT..."
    if ($DryRun) {
        Write-LogYellow "  [DRY-RUN] Would create Cloud Router $($s.NatRouter) and NAT $($s.NatName)"
    } else {
        $rtr = Invoke-GcloudCmd "gcloud compute routers describe $($s.NatRouter) --project=$proj --region=$region --format=json" -AsJson -Silent
        if ($rtr) {
            Write-LogGreen "  OK  Cloud Router exists: $($s.NatRouter)"
        } else {
            Invoke-GcloudCmd "gcloud compute routers create $($s.NatRouter) --project=$proj --network=$net --region=$region" -Silent
            Write-LogGreen "  OK  Created Cloud Router: $($s.NatRouter)"
        }
        $nat = Invoke-GcloudCmd "gcloud compute routers nats describe $($s.NatName) --router=$($s.NatRouter) --project=$proj --region=$region --format=json" -AsJson -Silent
        if ($nat) {
            Write-LogGreen "  OK  Cloud NAT exists: $($s.NatName)"
        } else {
            Invoke-GcloudCmd "gcloud compute routers nats create $($s.NatName) --router=$($s.NatRouter) --project=$proj --region=$region --auto-allocate-nat-external-ip --nat-all-subnet-ip-ranges" -Silent
            Write-LogGreen "  OK  Created Cloud NAT: $($s.NatName)"
        }
    }

    # ── Firewall ──
    # The counterpart of the OLH security group: all traffic from inside the
    # subnet. Egress needs no rule - GCP has an implied default-allow-egress.
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Network: Firewall..."
    if ($DryRun) {
        Write-LogYellow "  [DRY-RUN] Would create firewall rule $($s.FirewallRule) (ingress from $cidr)"
    } else {
        $fw = Invoke-GcloudCmd "gcloud compute firewall-rules describe $($s.FirewallRule) --project=$proj --format=json" -AsJson -Silent
        if ($fw) {
            Write-LogGreen "  OK  Firewall rule exists: $($s.FirewallRule)"
        } else {
            Invoke-GcloudCmd "gcloud compute firewall-rules create $($s.FirewallRule) --project=$proj --network=$net --direction=INGRESS --action=ALLOW --rules=tcp:0-65535 --source-ranges=$cidr --description=`"Qlik Open Lakehouse intra-cluster traffic`"" -Silent
            Write-LogGreen "  OK  Created firewall rule: $($s.FirewallRule) (ingress from $cidr)"
        }
    }

    # ── Cloud KMS ──
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Security: Cloud KMS..."
    Write-Log "`n  -- Security and Encryption --" -Bold $true
    $ring = $s.GcpKmsKeyRing
    $key  = $s.GcpKmsKeyName
    if ($DryRun) {
        Write-LogYellow "  [DRY-RUN] Would create key ring $ring and key $key"
    } else {
        $kr = Invoke-GcloudCmd "gcloud kms keyrings describe $ring --project=$proj --location=$region --format=json" -AsJson -Silent
        if ($kr) { Write-LogGreen "  OK  Key ring exists: $ring" }
        else {
            Invoke-GcloudCmd "gcloud kms keyrings create $ring --project=$proj --location=$region" -Silent
            Write-LogGreen "  OK  Created key ring: $ring"
        }
        $ck = Invoke-GcloudCmd "gcloud kms keys describe $key --project=$proj --location=$region --keyring=$ring --format=json" -AsJson -Silent
        if ($ck) { Write-LogGreen "  OK  Key exists: $key" }
        else {
            Invoke-GcloudCmd "gcloud kms keys create $key --project=$proj --location=$region --keyring=$ring --purpose=encryption" -Silent
            Write-LogGreen "  OK  Created key: $key"
        }
        Write-LogGray "      $($s.GcpKmsKeyId)"

        # Cloud Storage cannot write CMEK-encrypted objects until its own
        # service agent can use the key. Without this, bucket creation with
        # --default-encryption-key fails with an error that does not name the
        # cause.
        $agent = Invoke-GcloudCmd "gcloud storage service-agent --project=$proj" -Silent
        if ($agent) {
            $agent = ($agent -split "`n")[0].Trim()
            Invoke-GcloudCmd "gcloud kms keys add-iam-policy-binding $key --project=$proj --location=$region --keyring=$ring --member=`"serviceAccount:$agent`" --role=`"roles/cloudkms.cryptoKeyEncrypterDecrypter`"" -Silent
            Write-LogGreen "  OK  Storage service agent can use the key"
        } else {
            Write-LogYellow "  !!  Could not resolve the Cloud Storage service agent"
        }
    }

    # ── Service accounts ──
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Security: Service accounts..."
    $mgmtId = ($s.MgmtServiceAccount -split '@')[0]
    $nodeId = ($s.NodeServiceAccount -split '@')[0]
    foreach ($pair in @(@($mgmtId, $s.MgmtServiceAccount, "Qlik OLH management ($PREFIX)"),
                        @($nodeId, $s.NodeServiceAccount, "Qlik OLH nodes ($PREFIX)"))) {
        if ($DryRun) {
            Write-LogYellow "  [DRY-RUN] Would create service account $($pair[0])"
            continue
        }
        $sa = Invoke-GcloudCmd "gcloud iam service-accounts describe $($pair[1]) --project=$proj --format=json" -AsJson -Silent
        if ($sa) {
            Write-LogGreen "  OK  Service account exists: $($pair[1])"
        } else {
            Invoke-GcloudCmd "gcloud iam service-accounts create $($pair[0]) --project=$proj --display-name=`"$($pair[2])`"" -Silent
            Write-LogGreen "  OK  Created: $($pair[1])"
        }
    }

    # Project roles the management account needs to stand up and run the
    # cluster. Terraform adds the narrower, resource-scoped grants.
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Security: Management roles..."
    $mgmtRoles = @("roles/compute.instanceAdmin.v1", "roles/compute.networkUser", "roles/iam.serviceAccountUser")
    foreach ($role in $mgmtRoles) {
        if ($DryRun) { Write-LogYellow "  [DRY-RUN] Would grant $role"; continue }
        $r = Invoke-GcloudCmd "gcloud projects add-iam-policy-binding $proj --member=`"serviceAccount:$($s.MgmtServiceAccount)`" --role=`"$role`" --condition=None" -Silent
        if ($null -ne $r) { Write-LogGreen "  OK  Granted $role" }
        else { Write-LogYellow "  !!  Could not grant $role" }
    }

    # ── Cloud Storage buckets ──
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Storage: Cloud Storage buckets..."
    Write-Log "`n  -- Storage --" -Bold $true
    $labels = Build-GcpLabels
    foreach ($b in @(@($s.GcsTable, $true), @($s.GcsLanding, $true), @($s.GcsConfig, $true), @($s.GcsTfState, $false))) {
        $bn   = $b[0]
        $cmek = $b[1]
        if ($DryRun) { Write-LogYellow "  [DRY-RUN] Would create bucket: $bn"; continue }
        $exists = Invoke-GcloudCmd "gcloud storage buckets describe gs://$bn --project=$proj --format=json" -AsJson -Silent
        if ($exists) {
            Write-LogGreen "  OK  Bucket exists: $bn"
            continue
        }
        $enc = if ($cmek) { "--default-encryption-key=$($s.GcpKmsKeyId)" } else { "" }
        Invoke-GcloudCmd "gcloud storage buckets create gs://$bn --project=$proj --location=$region --uniform-bucket-level-access --public-access-prevention $enc" -Silent
        Invoke-GcloudCmd "gcloud storage buckets update gs://$bn --project=$proj --update-labels=$labels" -Silent
        $encNote = if ($cmek) { "CMEK" } else { "Google-managed encryption" }
        Write-LogGreen "  OK  Created: $bn ($encNote, uniform access, public access prevented)"
    }
    if (-not $DryRun) {
        # Terraform state benefits from versioning; the lakehouse buckets do not.
        Invoke-GcloudCmd "gcloud storage buckets update gs://$($s.GcsTfState) --project=$proj --versioning" -Silent
    }

    # ── Label compliance ──
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Verifying label compliance..."
    Write-Log "`n  -- Label Compliance --" -Bold $true
    $required = [ordered]@{
        owner = $s.Initials; environment = $s.Environment; workload = "qlik-olh"
        application = "open-lakehouse"; createdate = $s.CreateDate; managedby = "script"
    }
    $ok = $true
    foreach ($k in $required.Keys) {
        if ($required[$k]) { Write-LogGreen "  OK  $k = $($required[$k])" }
        else { Write-LogRed "  X   $k = (empty)"; $ok = $false }
    }
    if ($ok) { Write-LogGreen "  OK  All labels compliant" } else { Write-LogRed "  X  Label compliance failed!" }

    # ── Output files ──
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Writing output files..."
    Write-Log "`n  -- Output Files --" -Bold $true
    $modeComment = if ($DryRun) { "DRY-RUN" } else { "LIVE" }
    $tfDir = Get-TerraformDir
    if (-not (Test-Path -LiteralPath $tfDir)) { New-Item -ItemType Directory -Path $tfDir -Force | Out-Null }
    $tfvarsPath = Join-Path $tfDir "terraform.tfvars"
    $zonesHcl = "[" + (($s.GcpZones | ForEach-Object { '"' + $_ + '"' }) -join ", ") + "]"

    @"
# Generated by qlik_deploy_olh_gui.ps1
# $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# Cloud: Google Cloud   Mode: $modeComment
#
# Contains your QTC tenant ID. Keep it out of source control.

initials                   = "$($s.Initials)"
workload                   = "$($s.Workload)"
env                        = "$($s.Environment)"

gcp_project_id             = "$($s.GcpProjectId)"
gcp_project_number         = "$($s.GcpProjectNumber)"
gcp_region                 = "$region"
gcp_zones                  = $zonesHcl
tfstate_bucket             = "$($s.GcsTfState)"

network_name               = "$net"
subnetwork_name            = "$sub"
subnetwork_cidr            = "$cidr"
firewall_rule_name         = "$($s.FirewallRule)"

kms_key_id                 = "$($s.GcpKmsKeyId)"
mgmt_service_account_email = "$($s.MgmtServiceAccount)"
node_service_account_email = "$($s.NodeServiceAccount)"

qtc_auth_method            = "$($s.QtcAuthMethod)"
qtc_oidc_issuer_uri        = "$($s.QtcOidcIssuer)"
qtc_tenant_id              = "$($s.QtcTenantId)"

gcs_table_bucket           = "$($s.GcsTable)"
gcs_landing_bucket         = "$($s.GcsLanding)"
gcs_config_bucket          = "$($s.GcsConfig)"

# Labels
tag_owner      = "$($s.Initials)"
tag_env        = "$($s.Environment)"
tag_workload   = "qlik-olh"
tag_createdate = "$($s.CreateDate)"
"@ | Set-Content -Path $tfvarsPath -Encoding UTF8
    Write-LogGreen "  OK  $tfvarsPath"

    $qtcFile = Join-Path $script:ScriptDir "qlik-network-integration.txt"
    $sep55 = "-" * 55
    $eq64  = "=" * 64
    @"
$eq64
  Qlik Open Lakehouse -- QTC Network Integration Reference
  Cloud      : Google Cloud  (Private Preview)
  Generated  : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Prefix     : $PREFIX
  Mode       : $modeComment
$eq64

$sep55
  ENTITY                         VALUE
$sep55
  Project ID                   : $($s.GcpProjectId)
  Project Number               : $($s.GcpProjectNumber)
  Region                       : $region
  Zones                        : $($s.GcpZones -join ', ')
  VPC Network                  : $net
  Subnetwork                   : $sub
  Subnetwork CIDR              : $cidr
  Firewall Rule                : $($s.FirewallRule)
  Cloud NAT                    : $($s.NatName)
  Cloud KMS Key                : $($s.GcpKmsKeyId)
  Management Service Account   : $($s.MgmtServiceAccount)
  Node Service Account         : $($s.NodeServiceAccount)
  GCS Table Storage Bucket     : $($s.GcsTable)
  GCS Landing Bucket           : $($s.GcsLanding)
  GCS Config Bucket            : $($s.GcsConfig)
  QTC Auth Method              : $($s.QtcAuthMethod)
$sep55

  APPLIED LABELS
$sep55
  owner         : $($s.Initials)
  environment   : $($s.Environment)
  workload      : qlik-olh
  application   : open-lakehouse
  createdate    : $($s.CreateDate)
  managedby     : script
$sep55

  CREATED BY TERRAFORM
$sep55
  BigLake Catalog  : $($s.Initials)_$($s.Workload)_$($s.Environment)_catalog
  BigLake Database : $($s.Initials)_$($s.Workload)_$($s.Environment)_db
  BigQuery Mirror  : $($s.Initials)_$($s.Workload)_$($s.Environment)_mirror
  Secret prefix    : $($s.Initials)-$($s.Workload)-$($s.Environment)
$sep55

  PREVIEW NOTES
$sep55
  * Private Preview opened 2 Sep 2026; GA planned Q4 2026.
  * Ingestion scope at launch: CDC and SaaS sources only.
    Streaming (Kafka / GCS) and Qlik Replicate sources arrive later.
  * Zero-copy mirroring to BigQuery is a Google Cloud only feature.
  * The QTC authentication model on GCP is not yet published. This run
    configured '$($s.QtcAuthMethod)' - confirm it against your preview
    onboarding pack before treating it as final.
$sep55
"@ | Set-Content -Path $qtcFile -Encoding UTF8
    Write-LogGreen "  OK  qlik-network-integration.txt"

    # ── Terraform ──
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Terraform..."
    if (-not $DryRun -and $s.TerraformOk) {
        Write-Log "`n  -- Terraform ($tfDir) --" -Bold $true
        $initArgs = "init -reconfigure -backend-config=`"bucket=$($s.GcsTfState)`" -backend-config=`"prefix=qlik-lakehouse`""
        Invoke-TerraformFlow -WorkDir $tfDir -InitArgs $initArgs
    } elseif ($DryRun) {
        Write-LogYellow "  [DRY-RUN] Terraform steps skipped"
    } else {
        Write-LogYellow "  !!  Terraform not available - skipping init/plan/apply"
    }

    Update-Progress 100 "Complete"
    Write-Log ""
    Write-LogGreen "  Deployment finished."
    Write-LogCyan  "  Next: create the Network Integration in QTC, then the Lakehouse Cluster"
    Write-LogCyan  "        (Spot VM MIG across $($s.GcpZones -join ', ')), then connect the"
    Write-LogCyan  "        Google Lakehouse Runtime Catalog."
    Write-LogYellow "  Reminder: your tenant must be enrolled in the Google Cloud Private Preview."

    $s.Deploying = $false
    Deploy-Complete
}

#endregion

#region ── Navigation ─────────────────────────────────────────

$script:StepTitles = @("Welcome", "Identity", "Network", "Security", "Storage", "Deploy")

function Set-Cloud {
    param([string]$Cloud)

    $script:State.Cloud = $Cloud
    $isGcp = ($Cloud -eq "gcp")

    if ($script:Controls['lblCloudNote']) {
        if ($isGcp) {
            $script:Controls['lblCloudNote'].Text =
                "Private Preview opened 2 Sep 2026. CDC and SaaS sources only - streaming and Replicate come later. Your tenant must be enrolled."
        } else {
            $script:Controls['lblCloudNote'].Text =
                "Provisions the VPC, KMS, IAM, S3 and Kinesis resources Open Lakehouse needs."
        }
    }

    # Drift and teardown are implemented for AWS only.
    foreach ($key in @('rbModeDrift','rbModeTeardown')) {
        if ($script:Controls[$key]) {
            $script:Controls[$key].Enabled = -not $isGcp
            if ($isGcp -and $script:Controls[$key].Checked -and $script:Controls['rbModeDeploy']) {
                $script:Controls['rbModeDeploy'].Checked = $true
            }
        }
    }

    # Swap in the matching page set. Steps 0 and 5 are shared objects, so the
    # arrays overlap at both ends.
    if ($script:PanelsAws -and $script:PanelsGcp) {
        $script:Panels = if ($isGcp) { $script:PanelsGcp } else { $script:PanelsAws }
        Set-Step 0
    }

    Write-LogCyan "  Target cloud: $(Get-CloudLabel)"
    if ($isGcp) {
        Write-LogYellow "  !!  Google Cloud support is in Private Preview (opened 2 Sep 2026)."
        Write-LogGray   "      Scope: CDC and SaaS sources. No stream resource is provisioned."
    }
    Run-ToolCheck
}

function Set-Step {
    param([int]$Step)
    if ($Step -lt 0 -or $Step -ge $script:Panels.Count) { return }

    # Hide every panel from both cloud page sets, not just the active array -
    # otherwise a page from the other cloud can stay on screen after a switch.
    foreach ($panel in $script:AllPanels) { $panel.Visible = $false }

    # Show target panel
    $script:Panels[$Step].Visible = $true
    $script:State.CurrentStep = $Step

    # Update header
    $script:Controls['lblStepIndicator'].Text = "Step $Step of 5 - $($script:StepTitles[$Step])"

    # Update breadcrumbs
    for ($i = 0; $i -lt $script:StepTitles.Count; $i++) {
        $lbl = $script:Controls["lblBc$i"]
        if ($i -eq $Step) {
            $lbl.BackColor = [System.Drawing.Color]::White
            $lbl.ForeColor = $script:Blue
            $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
        } else {
            $lbl.BackColor = $script:LightBlue
            $lbl.ForeColor = [System.Drawing.Color]::Gray
            $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        }
    }

    # Update nav buttons
    $script:Controls['btnBack'].Enabled = ($Step -gt 0)
    if ($Step -eq 5) {
        $script:Controls['btnNext'].Visible = $false
    } else {
        $script:Controls['btnNext'].Visible = $true
        $script:Controls['btnNext'].Text = "Next >"
    }
}

function Validate-Step {
    param([int]$Step)
    if ($script:State.Cloud -eq "gcp") { return (Validate-StepGcp $Step) }

    switch ($Step) {
        0 {
            if (-not $script:State.AwsCliOk) {
                [System.Windows.Forms.MessageBox]::Show("AWS CLI is required. Click 'Check Tools' first.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            if (-not $script:State.TerraformOk) {
                $r = [System.Windows.Forms.MessageBox]::Show("Terraform is not available. Deploy steps will be skipped. Continue?", "Warning", 'YesNo', 'Warning')
                if ($r -ne 'Yes') { return $false }
            }
            return $true
        }
        1 {
            $init = $script:Controls['txtInitials'].Text
            if ($init -notmatch '^[a-z0-9]{2,6}$') {
                [System.Windows.Forms.MessageBox]::Show("Owner initials must be 2-6 lowercase alphanumeric characters.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            $wk = $script:Controls['txtWorkload'].Text
            if ($wk -notmatch '^[a-z0-9-]{2,10}$') {
                [System.Windows.Forms.MessageBox]::Show("Workload must be 2-10 lowercase alphanumeric or hyphen.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            $reg = $script:Controls['cboRegion'].Text
            if ($reg -notmatch '^[a-z]{2}-[a-z]+-[0-9]$') {
                [System.Windows.Forms.MessageBox]::Show("Invalid AWS region format (e.g. us-east-1).", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            if (-not $script:State.AwsAuthenticated) {
                $r = [System.Windows.Forms.MessageBox]::Show("AWS identity not verified. Continue anyway?", "Warning", 'YesNo', 'Warning')
                if ($r -ne 'Yes') { return $false }
            }
            return $true
        }
        2 {
            if (-not $script:State.VpcId -and -not $script:State.CreateNewVpc) {
                [System.Windows.Forms.MessageBox]::Show("Select a VPC or check 'Create New'.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            if ($script:State.CreateNewVpc) {
                $cidr = $script:Controls['txtNewVpcCidr'].Text
                if ($cidr -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') {
                    [System.Windows.Forms.MessageBox]::Show("Invalid CIDR format for new VPC.", "Validation", 'OK', 'Warning') | Out-Null
                    return $false
                }
            }
            # Open Lakehouse wants at least two subnets, in two different AZs.
            # The picker accepts anything, so the rule is enforced here rather
            # than surfacing later as a cluster that will not launch.
            if ($script:State.SubnetAzPairs.Count -lt 2) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Open Lakehouse requires at least two subnets, in two different Availability Zones.`n`nYou have selected $($script:State.SubnetAzPairs.Count).",
                    "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            $azs = @($script:State.SubnetAzPairs | ForEach-Object { $_.Az } | Select-Object -Unique)
            if ($azs.Count -lt 2) {
                [System.Windows.Forms.MessageBox]::Show(
                    "The selected subnets are all in one Availability Zone ($($azs -join ', ')).`n`nOpen Lakehouse spreads the cluster across two AZs.",
                    "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            if (-not $script:State.SgId -and -not $script:State.CreateNewSg) {
                [System.Windows.Forms.MessageBox]::Show("Select a Security Group or check 'Create New'.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            return $true
        }
        3 {
            if (-not $script:State.KmsKeyArn -and -not $script:State.CreateNewKms) {
                [System.Windows.Forms.MessageBox]::Show("Select a KMS key or check 'Create New'.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            $ext = $script:Controls['txtQtcExternalId'].Text.Trim()
            if ($ext -notmatch '^[A-Za-z0-9_.:/=+\-]{4,1224}$') {
                [System.Windows.Forms.MessageBox]::Show(
                    "Enter the ExternalId from your QTC tenant.`n`nIt is what the management role's trust policy requires; without it Qlik cannot assume the role and the network integration will not connect.",
                    "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            $proxy = $script:Controls['txtQlikProxyArn'].Text.Trim()
            if ($proxy -notmatch '^arn:aws[a-z\-]*:iam::[0-9]{12}:(role|user)/.+$') {
                [System.Windows.Forms.MessageBox]::Show(
                    "Enter the Qlik proxy principal ARN, e.g.`narn:aws:iam::<qlik-account>:role/qlik-proxy-assume-role",
                    "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            $script:State.QtcExternalId    = $ext
            $script:State.QlikProxyRoleArn = $proxy
            return $true
        }
        4 {
            foreach ($name in @('txtS3Iceberg','txtS3Landing','txtS3Config')) {
                $val = $script:Controls[$name].Text
                if ($val -notmatch '^[a-z0-9][a-z0-9\-]{1,61}[a-z0-9]$') {
                    [System.Windows.Forms.MessageBox]::Show("Invalid S3 bucket name: $val", "Validation", 'OK', 'Warning') | Out-Null
                    return $false
                }
            }
            $kin = $script:Controls['txtKinesis'].Text
            if ($kin -notmatch '^[a-zA-Z0-9_.\-]+$') {
                [System.Windows.Forms.MessageBox]::Show("Invalid Kinesis stream name.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            return $true
        }
    }
    return $true
}

function Validate-StepGcp {
    param([int]$Step)
    switch ($Step) {
        0 {
            if (-not $script:State.GcloudOk) {
                [System.Windows.Forms.MessageBox]::Show("The Google Cloud CLI is required. Click 'Check Tools' first.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            if (-not $script:State.TerraformOk) {
                $r = [System.Windows.Forms.MessageBox]::Show("Terraform is not available. Deploy steps will be skipped. Continue?", "Warning", 'YesNo', 'Warning')
                if ($r -ne 'Yes') { return $false }
            }
            return $true
        }
        1 {
            Sync-GcpState
            if ($script:State.Initials -notmatch '^[a-z0-9]{2,6}$') {
                [System.Windows.Forms.MessageBox]::Show("Owner initials must be 2-6 lowercase alphanumeric characters.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            if ($script:State.Workload -notmatch '^[a-z0-9-]{2,10}$') {
                [System.Windows.Forms.MessageBox]::Show("Workload must be 2-10 lowercase alphanumeric or hyphen.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            $reg = $script:State.Region
            $zones = @($script:Controls['txtGcpZones'].Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($zones.Count -lt 2) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Enter at least two zones.`n`nOpen Lakehouse spreads the cluster's Spot VMs across zones so a reclaim in one zone cannot take it down.",
                    "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            $bad = @($zones | Where-Object { $_ -notmatch "^$([regex]::Escape($reg))-[a-z]$" })
            if ($bad.Count -gt 0) {
                [System.Windows.Forms.MessageBox]::Show("These are not zones of ${reg}:`n`n$($bad -join ', ')", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            $script:State.GcpZones = $zones

            if (-not $script:State.GcpProjectId) {
                [System.Windows.Forms.MessageBox]::Show("Connect and select a project first.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            return $true
        }
        2 {
            $newNet = $script:Controls['chkGcpNewNetwork'].Checked
            if (-not $newNet -and -not $script:State.NetworkName) {
                [System.Windows.Forms.MessageBox]::Show("Select a VPC network or check 'Create new'.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            if ($newNet) { $script:State.NetworkName = $script:Controls['txtGcpNetworkNew'].Text.Trim() }

            $newSub = $script:Controls['chkGcpNewSubnet'].Checked
            if ($newSub) { $script:State.SubnetworkName = $script:Controls['txtGcpSubnetNew'].Text.Trim() }
            if (-not $script:State.SubnetworkName) {
                [System.Windows.Forms.MessageBox]::Show("Select a subnetwork or check 'Create new'.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }

            $cidr = $script:Controls['txtGcpSubnetCidr'].Text.Trim()
            if ($cidr -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') {
                [System.Windows.Forms.MessageBox]::Show("Invalid subnetwork CIDR.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            $script:State.SubnetworkCidr = $cidr

            # Private Google Access is a prerequisite, but an existing subnet
            # that has it off can still be fixed during deploy.
            if (-not $newSub -and -not $script:State.PrivateGoogleAccess) {
                $r = [System.Windows.Forms.MessageBox]::Show(
                    "Private Google Access is off on $($script:State.SubnetworkName).`n`nOpen Lakehouse needs it, and Terraform will refuse to plan without it. Enable it during deployment?",
                    "Private Google Access", 'YesNo', 'Warning')
                if ($r -ne 'Yes') { return $false }
            }

            $script:State.FirewallRule = $script:Controls['txtGcpFirewall'].Text.Trim()
            $script:State.NatRouter    = $script:Controls['txtGcpRouter'].Text.Trim()
            $script:State.NatName      = $script:Controls['txtGcpNat'].Text.Trim()
            foreach ($pair in @(@('firewall rule', $script:State.FirewallRule), @('Cloud Router', $script:State.NatRouter), @('Cloud NAT', $script:State.NatName))) {
                if ($pair[1] -notmatch '^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$') {
                    [System.Windows.Forms.MessageBox]::Show("Invalid $($pair[0]) name: $($pair[1])", "Validation", 'OK', 'Warning') | Out-Null
                    return $false
                }
            }
            return $true
        }
        3 {
            $ring = $script:Controls['txtGcpKeyRing'].Text.Trim()
            $key  = $script:Controls['txtGcpKeyName'].Text.Trim()
            foreach ($pair in @(@('key ring', $ring), @('key', $key))) {
                if ($pair[1] -notmatch '^[a-zA-Z0-9_-]{1,63}$') {
                    [System.Windows.Forms.MessageBox]::Show("Invalid KMS $($pair[0]) name: $($pair[1])", "Validation", 'OK', 'Warning') | Out-Null
                    return $false
                }
            }
            $script:State.GcpKmsKeyRing = $ring
            $script:State.GcpKmsKeyName = $key
            $script:State.GcpKmsKeyId   = "projects/$($script:State.GcpProjectId)/locations/$($script:State.Region)/keyRings/$ring/cryptoKeys/$key"

            $mgmt = $script:Controls['txtGcpMgmtSa'].Text.Trim()
            $node = $script:Controls['txtGcpNodeSa'].Text.Trim()
            foreach ($pair in @(@('management', $mgmt), @('node', $node))) {
                if ($pair[1] -notmatch '^[a-z][a-z0-9-]{4,28}[a-z0-9]$') {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Invalid $($pair[0]) service account ID: $($pair[1])`n`n6-30 characters, lowercase letters, digits and hyphens, starting with a letter.",
                        "Validation", 'OK', 'Warning') | Out-Null
                    return $false
                }
            }
            if ($mgmt -eq $node) {
                [System.Windows.Forms.MessageBox]::Show(
                    "The management and node service accounts must be different identities.`n`nQTC impersonates the management account from outside the project; the node account is attached to the VMs.",
                    "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            $script:State.MgmtServiceAccount = "$mgmt@$($script:State.GcpProjectId).iam.gserviceaccount.com"
            $script:State.NodeServiceAccount = "$node@$($script:State.GcpProjectId).iam.gserviceaccount.com"

            $tenant = $script:Controls['txtQtcTenantId'].Text.Trim()
            if ($tenant -notmatch '^[A-Za-z0-9_.:\-]{4,128}$') {
                [System.Windows.Forms.MessageBox]::Show("Enter your QTC tenant ID (from Administration > Network integrations).", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
            $script:State.QtcTenantId   = $tenant
            $script:State.QtcAuthMethod = [string]$script:Controls['cboQtcAuthMethod'].SelectedItem

            if ($script:State.QtcAuthMethod -eq "workload_identity") {
                $iss = $script:Controls['txtQtcIssuer'].Text.Trim()
                if ($iss -notmatch '^https://.+') {
                    [System.Windows.Forms.MessageBox]::Show("The OIDC issuer must be an https URL.", "Validation", 'OK', 'Warning') | Out-Null
                    return $false
                }
                $script:State.QtcOidcIssuer = $iss

                # Workload Identity pool IDs are capped at 32 characters.
                $poolId = "$($script:State.Prefix)-qtc-pool"
                if ($poolId.Length -gt 32) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "The Workload Identity pool ID derived from your naming ($poolId) is $($poolId.Length) characters; Google caps it at 32.`n`nShorten the initials or workload.",
                        "Validation", 'OK', 'Warning') | Out-Null
                    return $false
                }
            } else {
                $script:State.QtcOidcIssuer = ""
            }
            return $true
        }
        4 {
            foreach ($name in @('txtGcsTable','txtGcsLanding','txtGcsConfig','txtGcsTfState')) {
                $val = $script:Controls[$name].Text.Trim()
                if ($val -notmatch '^[a-z0-9][a-z0-9._\-]{1,61}[a-z0-9]$') {
                    [System.Windows.Forms.MessageBox]::Show("Invalid Cloud Storage bucket name: $val", "Validation", 'OK', 'Warning') | Out-Null
                    return $false
                }
            }
            $script:State.GcsTable   = $script:Controls['txtGcsTable'].Text.Trim()
            $script:State.GcsLanding = $script:Controls['txtGcsLanding'].Text.Trim()
            $script:State.GcsConfig  = $script:Controls['txtGcsConfig'].Text.Trim()
            $script:State.GcsTfState = $script:Controls['txtGcsTfState'].Text.Trim()
            return $true
        }
    }
    return $true
}

#endregion

#region ── Main Form ──────────────────────────────────────────

$form = New-Object System.Windows.Forms.Form
$form.Text            = "Qlik Open Lakehouse - AWS Deployment Wizard"
$form.Size            = [System.Drawing.Size]::new(820, 750)
$form.StartPosition   = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox     = $false
$form.Font            = New-Object System.Drawing.Font("Segoe UI", 9)
$form.BackColor       = $script:BgColor

# ── Header Panel ──
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Location  = [System.Drawing.Point]::new(0, 0)
$pnlHeader.Size       = [System.Drawing.Size]::new(820, 55)
$pnlHeader.BackColor  = $script:QlikNavy

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = "Qlik Open Lakehouse"
$lblTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Location  = [System.Drawing.Point]::new(15, 5)
$lblTitle.AutoSize  = $true
$pnlHeader.Controls.Add($lblTitle)

$lblStep = New-Object System.Windows.Forms.Label
$lblStep.Text      = "Step 0 of 5 - Welcome"
$lblStep.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$lblStep.ForeColor = [System.Drawing.Color]::FromArgb(200, 240, 215)
$lblStep.Location  = [System.Drawing.Point]::new(15, 32)
$lblStep.AutoSize  = $true
$script:Controls['lblStepIndicator'] = $lblStep
$pnlHeader.Controls.Add($lblStep)

$form.Controls.Add($pnlHeader)

# ── Breadcrumb Panel ──
$pnlBread = New-Object System.Windows.Forms.Panel
$pnlBread.Location = [System.Drawing.Point]::new(0, 55)
$pnlBread.Size     = [System.Drawing.Size]::new(820, 32)
$pnlBread.BackColor = $script:LightBlue

$bcX = 10
foreach ($i in 0..5) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = "  $($script:StepTitles[$i])  "
    $lbl.Location  = [System.Drawing.Point]::new($bcX, 5)
    $lbl.Size      = [System.Drawing.Size]::new(120, 22)
    $lbl.TextAlign = 'MiddleCenter'
    $lbl.Font      = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $lbl.ForeColor = [System.Drawing.Color]::Gray
    $lbl.BackColor = $script:LightBlue
    $script:Controls["lblBc$i"] = $lbl
    $pnlBread.Controls.Add($lbl)
    $bcX += 130
}

$form.Controls.Add($pnlBread)

# ── Content Panel ──
$pnlContent = New-Object System.Windows.Forms.Panel
$pnlContent.Location = [System.Drawing.Point]::new(10, 92)
$pnlContent.Size     = [System.Drawing.Size]::new(785, 380)
$pnlContent.BackColor = [System.Drawing.Color]::White
$pnlContent.BorderStyle = 'FixedSingle'
$form.Controls.Add($pnlContent)

# ── Log Panel ──
$pnlLog = New-Object System.Windows.Forms.Panel
$pnlLog.Location = [System.Drawing.Point]::new(10, 477)
$pnlLog.Size     = [System.Drawing.Size]::new(785, 155)

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Dock      = 'Fill'
$rtbLog.ReadOnly  = $true
$rtbLog.BackColor = $script:DarkBg
$rtbLog.ForeColor = $script:LogFg
$rtbLog.Font      = New-Object System.Drawing.Font("Consolas", 8.5)
$rtbLog.BorderStyle = 'None'
$script:Controls['rtbLog'] = $rtbLog
$pnlLog.Controls.Add($rtbLog)

$form.Controls.Add($pnlLog)

# ── Navigation Panel ──
$pnlNav = New-Object System.Windows.Forms.Panel
$pnlNav.Location  = [System.Drawing.Point]::new(0, 637)
$pnlNav.Size      = [System.Drawing.Size]::new(820, 75)
$pnlNav.BackColor = $script:BgColor

$btnBack = New-Btn "< Back" 20 18 100 35 {
    Set-Step ($script:State.CurrentStep - 1)
}
$btnBack.Enabled = $false
$script:Controls['btnBack'] = $btnBack
$pnlNav.Controls.Add($btnBack)

$btnNext = New-Btn "Next >" 570 18 100 35 {
    $cur = $script:State.CurrentStep
    if (Validate-Step $cur) {
        Set-Step ($cur + 1)
    }
}
$btnNext.BackColor = $script:Blue
$btnNext.ForeColor = [System.Drawing.Color]::White
$btnNext.FlatAppearance.BorderSize = 0
$script:Controls['btnNext'] = $btnNext
$pnlNav.Controls.Add($btnNext)

$btnCancel = New-Btn "Cancel" 690 18 100 35 {
    if ($script:State.Deploying) {
        [System.Windows.Forms.MessageBox]::Show("A deployment is in progress. Please wait.", "Info", 'OK', 'Information') | Out-Null
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show("Are you sure you want to cancel?", "Confirm", 'YesNo', 'Question')
    if ($r -eq 'Yes') { $form.Close() }
}
$pnlNav.Controls.Add($btnCancel)

$form.Controls.Add($pnlNav)

# ── Build Steps and Show ──
# Steps 0 and 5 are shared; steps 1-4 exist once per cloud and are swapped by
# Set-Cloud, because the resources they collect have no useful overlap.
$pnlStep0 = Build-Step0
$pnlStep5 = Build-Step5

$script:PanelsAws = @($pnlStep0, (Build-Step1), (Build-Step2), (Build-Step3), (Build-Step4), $pnlStep5)
$script:PanelsGcp = @($pnlStep0, (Build-Step1Gcp), (Build-Step2Gcp), (Build-Step3Gcp), (Build-Step4Gcp), $pnlStep5)

$script:AllPanels = @()
foreach ($set in @($script:PanelsAws, $script:PanelsGcp)) {
    foreach ($panel in $set) {
        if ($script:AllPanels -notcontains $panel) { $script:AllPanels += $panel }
    }
}

foreach ($panel in $script:AllPanels) {
    $panel.Location = [System.Drawing.Point]::new(0, 0)
    $panel.Size     = [System.Drawing.Size]::new(785, 380)
    $panel.Visible  = $false
    $pnlContent.Controls.Add($panel)
}

$script:Panels = $script:PanelsAws
Set-Step 0

# Welcome message in log
Write-LogCyan "  Qlik Open Lakehouse - Deployment Wizard (AWS + Google Cloud)"
Write-LogGray "  Checking tools..."

# Seeds the cloud note, mode radios and tool check in one pass.
Set-Cloud "aws"

# Form closing guard
$form.Add_FormClosing({
    if ($script:State.Deploying) {
        $r = [System.Windows.Forms.MessageBox]::Show("A deployment is in progress. Force close?", "Warning", 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $_.Cancel = $true }
    }
})

#endregion

#region ── Entry Point ────────────────────────────────────────

[System.Windows.Forms.Application]::Run($form)

#endregion
