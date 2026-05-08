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

#region ── Script-Level State ─────────────────────────────────

$script:State = @{
    Mode             = "Deploy"
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
    CreateNewRole    = $false
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

function Invoke-AwsCmd {
    param([string]$Command, [switch]$AsJson, [switch]$Silent)
    if (-not $Silent) { Write-LogGray "  -> $Command" }
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
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
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
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
    } finally {
        Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
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
    # AWS CLI check
    $awsFound = [bool](Get-Command "aws" -ErrorAction SilentlyContinue)
    $script:State.AwsCliOk = $awsFound
    if ($awsFound) {
        try {
            $raw = (aws --version 2>&1) -replace "`n",""
            # Extract just "aws-cli/2.x.x" to avoid wrapping
            if ($raw -match '(aws-cli/[\d\.]+)') { $v = $Matches[1] } else { $v = "found" }
        } catch { $v = "found" }
        $script:State.AwsCliVersion = $v
        $script:Controls['lblAwsStatus'].Text = "[OK]  AWS CLI - $v   (latest installer always pulls v2)"
        $script:Controls['lblAwsStatus'].ForeColor = [System.Drawing.Color]::DarkGreen
        # Always offer an "Update" path -- the AWS MSI will upgrade in place
        $script:Controls['btnInstallAws'].Text    = "Update AWS CLI..."
        $script:Controls['btnInstallAws'].Visible = $true
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

        try {
            if ($rbWinget.Checked) {
                $pkgId = if ($Tool -eq "Terraform") { "HashiCorp.Terraform" } else { "Amazon.AWSCLI" }
                $lblProg.Text = "Running: winget install $pkgId ..."
                [System.Windows.Forms.Application]::DoEvents()
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "winget"
                $psi.Arguments = "install --id $pkgId --exact --silent --accept-package-agreements --accept-source-agreements"
                $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
                $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                $stdout = $proc.StandardOutput.ReadToEnd()
                $stderr = $proc.StandardError.ReadToEnd()
                $proc.WaitForExit()
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
                $psi.FileName = "choco"; $psi.Arguments = "install $pkgId -y"
                $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
                $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                $stdout = $proc.StandardOutput.ReadToEnd()
                $stderr = $proc.StandardError.ReadToEnd()
                $proc.WaitForExit()
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
                    $proc = [System.Diagnostics.Process]::Start($psi)
                    $proc.WaitForExit()
                    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
                    if ($proc.ExitCode -ne 0) {
                        $errMsg = "msiexec exit $($proc.ExitCode). See log: $logPath"
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

    $p.Controls.Add((New-Label "Welcome to Qlik Open Lakehouse Deployment Wizard" 20 10 720 30 -Bold -FontSize 12))
    $p.Controls.Add((New-Label "This wizard will guide you through discovering and provisioning AWS resources for Qlik's Open Lakehouse architecture." 20 45 720 35))

    # Tool Status GroupBox - full width for better readability
    $grpTools = New-Object System.Windows.Forms.GroupBox
    $grpTools.Text     = "Prerequisite Tools"
    $grpTools.Location = [System.Drawing.Point]::new(20, 85)
    $grpTools.Size     = [System.Drawing.Size]::new(720, 140)

    # AWS CLI row
    $lblAws = New-Label "[ ? ]  AWS CLI - not checked" 15 28 400 22
    $lblAws.Name = "lblAwsStatus"
    $script:Controls['lblAwsStatus'] = $lblAws
    $grpTools.Controls.Add($lblAws)

    $btnInstAws = New-Btn "Install AWS CLI..." 490 25 120 26 { Show-InstallDialog "AWS CLI" }
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

    $lblCheckHint = New-Label "Verifies AWS CLI and Terraform are installed and on PATH" 145 100 400
    $lblCheckHint.ForeColor = [System.Drawing.Color]::Gray
    $lblCheckHint.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $grpTools.Controls.Add($lblCheckHint)

    $btnInstBoth = New-Btn "Install Both..." 620 95 90 30 {
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
    $grpMode.Location = [System.Drawing.Point]::new(20, 235)
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

    $p.Controls.Add((New-Label "Security and Encryption" 20 5 720 28 -Bold -FontSize 11))

    # KMS Section
    $p.Controls.Add((New-Label "KMS Symmetric Key" 20 40 300 22 -Bold))
    $p.Controls.Add((& { $l = New-Label "Select an existing KMS key or create a new one for resource encryption." 20 62 720; $l.ForeColor = [System.Drawing.Color]::Gray; $l }))

    $cboKms = New-ComboBox "cboKms" 20 90 480
    $cboKms.Add_SelectedIndexChanged({
        if ($this.SelectedIndex -ge 0 -and $script:State.KmsList.Count -gt $this.SelectedIndex) {
            $sel = $script:State.KmsList[$this.SelectedIndex]
            $script:State.KmsKeyArn = "arn:aws:kms:$($script:State.Region):$($script:State.AccountId):key/$($sel.KeyId)"
        }
    })
    $p.Controls.Add($cboKms)

    $btnRefKms = New-Btn "Refresh" 510 89 80 26 {
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
    $chkNewKms.Text = "Create New"; $chkNewKms.Location = [System.Drawing.Point]::new(600, 92); $chkNewKms.Size = [System.Drawing.Size]::new(110, 22)
    $chkNewKms.Add_CheckedChanged({
        $script:State.CreateNewKms = $this.Checked
        $script:Controls['cboKms'].Enabled = -not $this.Checked
    })
    $p.Controls.Add($chkNewKms)

    # IAM Role Section
    $p.Controls.Add((New-Sep 20 130 720))
    $p.Controls.Add((New-Label "IAM Management Role" 20 145 300 22 -Bold))
    $p.Controls.Add((& { $l = New-Label "EC2 trust policy role for instance management. SSM Core policy auto-attached." 20 167 720; $l.ForeColor = [System.Drawing.Color]::Gray; $l }))

    $cboRole = New-ComboBox "cboRole" 20 195 480
    $cboRole.Add_SelectedIndexChanged({
        if ($this.SelectedIndex -ge 0 -and $script:State.RoleList.Count -gt $this.SelectedIndex) {
            $script:State.MgmtRoleArn = $script:State.RoleList[$this.SelectedIndex].Arn
        }
    })
    $p.Controls.Add($cboRole)

    $btnRefRole = New-Btn "Refresh" 510 194 80 26 {
        Write-LogGray "  Discovering IAM roles..."
        $raw = Invoke-AwsCmd "aws iam list-roles --query `"Roles[?contains(RoleName,'$($script:State.Prefix)')].{Name:RoleName,Arn:Arn}`" --output json" -AsJson -Silent
        $cbo = $script:Controls['cboRole']
        $cbo.Items.Clear()
        $script:State.RoleList = @()
        if ($raw) {
            $script:State.RoleList = @($raw)
            foreach ($r in $raw) { $cbo.Items.Add("$($r.Name)  |  $($r.Arn)") | Out-Null }
            Write-LogGreen "  Found $($raw.Count) IAM role(s) matching prefix"
        } else {
            Write-LogYellow "  No IAM roles found with prefix $($script:State.Prefix)"
        }
    }
    $p.Controls.Add($btnRefRole)

    $chkNewRole = New-Object System.Windows.Forms.CheckBox
    $chkNewRole.Text = "Create New"; $chkNewRole.Location = [System.Drawing.Point]::new(600, 197); $chkNewRole.Size = [System.Drawing.Size]::new(110, 22)
    $chkNewRole.Add_CheckedChanged({
        $script:State.CreateNewRole = $this.Checked
        $script:Controls['cboRole'].Enabled = -not $this.Checked
    })
    $p.Controls.Add($chkNewRole)

    # Instance Profile
    $p.Controls.Add((New-Sep 20 240 720))
    $p.Controls.Add((New-Label "EC2 Instance Profile" 20 255 300 22 -Bold))
    $lblProf = New-Label "" 20 280 720 40
    $lblProf.ForeColor = [System.Drawing.Color]::Gray
    $script:Controls['lblProfileInfo'] = $lblProf
    $p.Controls.Add($lblProf)

    $p.Add_VisibleChanged({
        if ($this.Visible) {
            $script:Controls['lblProfileInfo'].Text = "An instance profile '$($script:State.Prefix)-instance-profile' will be auto-created and linked to the selected IAM role."
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
            if ($result -ne $null -or $LASTEXITCODE -eq 0) {
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
        $rpt = Join-Path $PWD "deploy-report.html"
        if (Test-Path $rpt) { Start-Process $rpt }
    }
    $btnReport.Visible = $false
    $script:Controls['btnOpenReport'] = $btnReport
    $p.Controls.Add($btnReport)

    # Open QTC File
    $btnQtc = New-Btn "Open QTC Ref" 650 280 110 28 {
        $qtc = Join-Path $PWD "qlik-network-integration.txt"
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
    $roleNote  = if ($s.CreateNewRole){ "[NEW]" } else { "[existing]" }

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
  IAM Role:       $($s.MgmtRoleArn) $roleNote
  Instance Profile: $($s.Prefix)-instance-profile

  --- Storage ---
  S3 Iceberg:     $($script:Controls['txtS3Iceberg'].Text)
  S3 Landing:     $($script:Controls['txtS3Landing'].Text)
  S3 Config:      $($script:Controls['txtS3Config'].Text)
  Kinesis Stream: $($script:Controls['txtKinesis'].Text)
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

function Start-Deploy {
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

        $tfvarsPath = Join-Path $PWD "terraform.tfvars"
        if (-not (Test-Path $tfvarsPath)) {
            Write-LogRed "  X  terraform.tfvars not found. Run a deployment first."
            Deploy-Complete; return
        }
        $tfContent = Get-Content $tfvarsPath -Raw
        function Local:Get-TfVal { param([string]$Key, [string]$Content)
            if ($Content -match "$Key\s*=\s*`"([^`"]+)`"") { return $Matches[1] }; return "(not set)"
        }

        Update-Progress 30 "Checking VPC..."
        $tfVpc = Local:Get-TfVal "vpc_id" $tfContent
        $liveVpc = Invoke-AwsCmd "aws ec2 describe-vpcs --region $($s.Region) --filters `"Name=tag:Name,Values=$PREFIX-vpc`" --query `"Vpcs[0].VpcId`" --output text" -Silent
        $st = if ($tfVpc -eq $liveVpc) { "MATCH" } else { "DRIFT" }
        if ($st -eq "MATCH") { Write-LogGreen "  VPC:  $tfVpc  ->  $st" } else { Write-LogRed "  VPC:  Expected=$tfVpc  Live=$liveVpc  ->  $st" }

        Update-Progress 50 "Checking Security Group..."
        $tfSg = Local:Get-TfVal "security_group_id" $tfContent
        $liveSg = Invoke-AwsCmd "aws ec2 describe-security-groups --region $($s.Region) --filters `"Name=tag:Name,Values=$PREFIX-sg`" --query `"SecurityGroups[0].GroupId`" --output text" -Silent
        $st = if ($tfSg -eq $liveSg) { "MATCH" } else { "DRIFT" }
        if ($st -eq "MATCH") { Write-LogGreen "  SG:   $tfSg  ->  $st" } else { Write-LogRed "  SG:   Expected=$tfSg  Live=$liveSg  ->  $st" }

        Update-Progress 70 "Checking Kinesis..."
        $tfKin = Local:Get-TfVal "kinesis_stream_name" $tfContent
        $liveKin = Invoke-AwsCmd "aws kinesis describe-stream-summary --stream-name `"$PREFIX-stream-kinesis`" --region $($s.Region) --query `"StreamDescriptionSummary.StreamName`" --output text" -Silent
        $st = if ($tfKin -eq $liveKin) { "MATCH" } else { "DRIFT" }
        if ($st -eq "MATCH") { Write-LogGreen "  Kinesis: $tfKin  ->  $st" } else { Write-LogRed "  Kinesis: Expected=$tfKin  Live=$liveKin  ->  $st" }

        Update-Progress 100 "Drift detection complete"
        Write-LogGreen "`n  OK  Drift detection complete."
        Deploy-Complete; return
    }

    # ── Teardown Mode ──
    if ($s.Mode -eq "Teardown") {
        Update-Progress 5 "Starting teardown..."
        Write-LogRed "  !! TEARDOWN: Destroying resources for $PREFIX"

        if ($script:State.TerraformOk) {
            Update-Progress 15 "Running terraform destroy..."
            Write-LogGray "  -> terraform destroy -auto-approve -var-file=terraform.tfvars"
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "terraform"; $psi.Arguments = "destroy -auto-approve -var-file=terraform.tfvars"
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.WaitForExit()
        }

        Update-Progress 40 "Removing S3 buckets..."
        foreach ($bucket in @("$PREFIX-iceberg-s3","$PREFIX-landing-s3","$PREFIX-config-s3")) {
            Write-LogGray "  -> Emptying & deleting: $bucket"
            Invoke-AwsCmd "aws s3 rm s3://$bucket --recursive --region $($s.Region)" -Silent
            Invoke-AwsCmd "aws s3api delete-bucket --bucket $bucket --region $($s.Region)" -Silent
            Write-LogGreen "  OK  Removed: $bucket"
        }

        Update-Progress 60 "Removing Kinesis stream..."
        Invoke-AwsCmd "aws kinesis delete-stream --stream-name $PREFIX-stream-kinesis --region $($s.Region)" -Silent
        Write-LogGreen "  OK  Kinesis stream removed"

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
    $services = @{
        "EC2"     = @("ec2:CreateVpc","ec2:CreateSubnet","ec2:CreateSecurityGroup","ec2:DescribeVpcs")
        "S3"      = @("s3:CreateBucket","s3:PutBucketPolicy","s3:PutEncryptionConfiguration")
        "IAM"     = @("iam:CreateRole","iam:CreateInstanceProfile","iam:AttachRolePolicy")
        "KMS"     = @("kms:CreateKey","kms:CreateAlias","kms:TagResource")
        "Kinesis" = @("kinesis:CreateStream","kinesis:DescribeStream")
        "Glue"    = @("glue:CreateDatabase","glue:GetDatabase")
        "STS"     = @("sts:GetCallerIdentity")
    }
    foreach ($svc in $services.Keys) {
        Write-LogGreen "  OK  $svc permissions assumed"
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

    # Step 6: Security Group
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Network: Security Group..."
    $SG_ID = $s.SgId
    if ($s.CreateNewSg) {
        if ($DryRun) {
            $SG_ID = "sg-DRYRUN"; Write-LogYellow "  [DRY-RUN] Would create security group $PREFIX-sg"
        } else {
            Write-LogGray "  Creating $PREFIX-sg (egress 443 only)..."
            $sgOut = Invoke-AwsCmd "aws ec2 create-security-group --group-name `"$PREFIX-sg`" --description `"Qlik OLH $PREFIX`" --vpc-id $VPC_ID --region $($s.Region) --tag-specifications `"$(Build-TagSpec 'security-group' "$PREFIX-sg")`" --output json" -AsJson
            if ($sgOut) {
                $SG_ID = $sgOut.GroupId
                Invoke-AwsCmd "aws ec2 authorize-security-group-egress --group-id $SG_ID --region $($s.Region) --ip-permissions `"IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]`"" -Silent
                Write-LogGreen "  OK  Created SG: $SG_ID"
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

    # Step 8: IAM Role
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Security: IAM Role..."
    $MGMT_ROLE_ARN = $s.MgmtRoleArn
    if ($s.CreateNewRole) {
        $trustPolicy = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
        if ($DryRun) {
            $MGMT_ROLE_ARN = "arn:aws:iam::${acctId}:role/$PREFIX-ec2-role-iam-DRYRUN"
            Write-LogYellow "  [DRY-RUN] Would create IAM role $PREFIX-ec2-role-iam"
        } else {
            Write-LogGray "  Creating IAM role $PREFIX-ec2-role-iam..."
            Invoke-AwsCmd "aws iam create-role --role-name `"$PREFIX-ec2-role-iam`" --assume-role-policy-document '$trustPolicy' --tags `"Key=Owner,Value=$($s.Initials)`" `"Key=Environment,Value=$($s.Environment)`" `"Key=Workload,Value=qlik-olh`" `"Key=CreateDate,Value=$($s.CreateDate)`" `"Key=ManagedBy,Value=script`"" -Silent
            $MGMT_ROLE_ARN = "arn:aws:iam::${acctId}:role/$PREFIX-ec2-role-iam"
            Invoke-AwsCmd "aws iam attach-role-policy --role-name `"$PREFIX-ec2-role-iam`" --policy-arn `"arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore`"" -Silent
            Write-LogGreen "  OK  Created: $MGMT_ROLE_ARN"
        }
    } else {
        Write-LogGreen "  OK  Using role: $MGMT_ROLE_ARN"
    }

    # Step 9: Instance Profile
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Security: Instance Profile..."
    $INSTANCE_PROFILE_ARN = $s.InstanceProfileArn
    if ($s.CreateNewRole) {
        if ($DryRun) {
            $INSTANCE_PROFILE_ARN = "arn:aws:iam::${acctId}:instance-profile/$PREFIX-instance-profile-DRYRUN"
            Write-LogYellow "  [DRY-RUN] Would create instance profile"
        } else {
            Write-LogGray "  Creating instance profile..."
            Invoke-AwsCmd "aws iam create-instance-profile --instance-profile-name `"$PREFIX-instance-profile`" --tags `"Key=Owner,Value=$($s.Initials)`" `"Key=Environment,Value=$($s.Environment)`" `"Key=CreateDate,Value=$($s.CreateDate)`"" -Silent
            Invoke-AwsCmd "aws iam add-role-to-instance-profile --instance-profile-name `"$PREFIX-instance-profile`" --role-name `"$PREFIX-ec2-role-iam`"" -Silent
            $INSTANCE_PROFILE_ARN = "arn:aws:iam::${acctId}:instance-profile/$PREFIX-instance-profile"
            Write-LogGreen "  OK  Created: $INSTANCE_PROFILE_ARN"
        }
    }

    # Step 10: S3 Buckets
    $step++; Update-Progress ([int]($step/$totalSteps*100)) "Storage: S3 Buckets..."
    Write-Log "`n  -- Storage and Streaming --" -Bold $true
    $S3_ICEBERG = $script:Controls['txtS3Iceberg'].Text
    $S3_LANDING = $script:Controls['txtS3Landing'].Text
    $S3_CONFIG  = $script:Controls['txtS3Config'].Text
    $TFSTATE_BUCKET = "$PREFIX-tfstate-s3"

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
                    Invoke-AwsCmd "aws s3api create-bucket --bucket $bn --region $($s.Region)" -Silent
                } else {
                    Invoke-AwsCmd "aws s3api create-bucket --bucket $bn --region $($s.Region) --create-bucket-configuration `"LocationConstraint=$($s.Region)`"" -Silent
                }
                Invoke-AwsCmd "aws s3api put-bucket-encryption --bucket $bn --server-side-encryption-configuration '{`"Rules`":[{`"ApplyServerSideEncryptionByDefault`":{`"SSEAlgorithm`":`"aws:kms`"}}]}'" -Silent
                Invoke-AwsCmd "aws s3api put-public-access-block --bucket $bn --public-access-block-configuration `"BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true`"" -Silent
                Invoke-AwsCmd "aws s3api put-bucket-tagging --bucket $bn --tagging `"TagSet=[{Key=Owner,Value=$($s.Initials)},{Key=Environment,Value=$($s.Environment)},{Key=Workload,Value=qlik-olh},{Key=CreateDate,Value=$($s.CreateDate)},{Key=ManagedBy,Value=script}]`"" -Silent
                Write-LogGreen "  OK  Created: $bn (KMS-encrypted, tagged)"
            }
        }
    }

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
            Invoke-AwsCmd "aws kinesis create-stream --stream-name $KINESIS_NAME --shard-count 2 --region $($s.Region)" -Silent
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
    $tfvarsPath = Join-Path $PWD "terraform.tfvars"

    @"
# Generated by qlik_deploy_olh_gui.ps1
# $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# Mode: $modeComment

initials             = "$($s.Initials)"
workload             = "$($s.Workload)"
env                  = "$($s.Environment)"
aws_region           = "$($s.Region)"
aws_account_id       = "$acctId"
tfstate_bucket       = "$TFSTATE_BUCKET"
vpc_id               = "$VPC_ID"
vpc_cidr             = "$VPC_CIDR"
kinesis_stream_name  = "$KINESIS_NAME"
kinesis_shards       = 2
s3_bucket_name       = "$S3_ICEBERG"
security_group_id    = "$SG_ID"
kms_key_arn          = "$KMS_KEY_ARN"
mgmt_role_arn        = "$MGMT_ROLE_ARN"
instance_profile_arn = "$INSTANCE_PROFILE_ARN"

# Tags
tag_owner      = "$($s.Initials)"
tag_env        = "$($s.Environment)"
tag_workload   = "qlik-olh"
tag_createdate = "$($s.CreateDate)"
"@ | Set-Content -Path $tfvarsPath -Encoding UTF8
    Write-LogGreen "  OK  terraform.tfvars"

    # QTC Reference file
    $qtcFile = Join-Path $PWD "qlik-network-integration.txt"
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
  Management Role ARN          : $MGMT_ROLE_ARN
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
    $rptFile = Join-Path $PWD "deploy-report.html"
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
  <span class="chip ok">Deployment Complete</span>
  <span class="chip ok">Tags Compliant</span>
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
        Write-Log "`n  -- Terraform --" -Bold $true
        Write-LogGray "  -> terraform init"
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "terraform"
        $psi.Arguments = "init -reconfigure -backend-config=`"bucket=$TFSTATE_BUCKET`" -backend-config=`"key=qlik-lakehouse/terraform.tfstate`" -backend-config=`"region=$($s.Region)`""
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $PWD.Path
        $proc = [System.Diagnostics.Process]::Start($psi)
        $tfOut = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -eq 0) {
            Write-LogGreen "  OK  terraform init complete"
            Write-LogGray "  -> terraform plan"
            $psi2 = New-Object System.Diagnostics.ProcessStartInfo
            $psi2.FileName = "terraform"
            $psi2.Arguments = "plan -var-file=`"$tfvarsPath`" -out=`"tfplan`""
            $psi2.RedirectStandardOutput = $true; $psi2.RedirectStandardError = $true
            $psi2.UseShellExecute = $false; $psi2.CreateNoWindow = $true
            $psi2.WorkingDirectory = $PWD.Path
            $proc2 = [System.Diagnostics.Process]::Start($psi2)
            $proc2.StandardOutput.ReadToEnd() | Out-Null
            $proc2.WaitForExit()
            if ($proc2.ExitCode -eq 0) {
                Write-LogGreen "  OK  terraform plan saved to tfplan"
                $r = [System.Windows.Forms.MessageBox]::Show("Terraform plan is ready. Apply now?", "Terraform Apply", 'YesNo', 'Question')
                if ($r -eq 'Yes') {
                    Write-LogGray "  -> terraform apply tfplan"
                    $psi3 = New-Object System.Diagnostics.ProcessStartInfo
                    $psi3.FileName = "terraform"; $psi3.Arguments = "apply `"tfplan`""
                    $psi3.RedirectStandardOutput = $true; $psi3.RedirectStandardError = $true
                    $psi3.UseShellExecute = $false; $psi3.CreateNoWindow = $true
                    $psi3.WorkingDirectory = $PWD.Path
                    $proc3 = [System.Diagnostics.Process]::Start($psi3)
                    $proc3.StandardOutput.ReadToEnd() | Out-Null
                    $proc3.WaitForExit()
                    if ($proc3.ExitCode -eq 0) { Write-LogGreen "  OK  terraform apply complete!" }
                    else { Write-LogRed "  X  terraform apply failed" }
                }
            } else { Write-LogRed "  X  terraform plan failed" }
        } else { Write-LogRed "  X  terraform init failed" }
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

#region ── Navigation ─────────────────────────────────────────

$script:StepTitles = @("Welcome", "Identity", "Network", "Security", "Storage", "Deploy")

function Set-Step {
    param([int]$Step)
    if ($Step -lt 0 -or $Step -ge $script:Panels.Count) { return }

    # Hide all panels
    foreach ($panel in $script:Panels) { $panel.Visible = $false }

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
            if ($script:State.SubnetAzPairs.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show("Add at least one subnet.", "Validation", 'OK', 'Warning') | Out-Null
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
            if (-not $script:State.MgmtRoleArn -and -not $script:State.CreateNewRole) {
                [System.Windows.Forms.MessageBox]::Show("Select an IAM role or check 'Create New'.", "Validation", 'OK', 'Warning') | Out-Null
                return $false
            }
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
$script:Panels += Build-Step0
$script:Panels += Build-Step1
$script:Panels += Build-Step2
$script:Panels += Build-Step3
$script:Panels += Build-Step4
$script:Panels += Build-Step5

foreach ($panel in $script:Panels) {
    $panel.Location = [System.Drawing.Point]::new(0, 0)
    $panel.Size     = [System.Drawing.Size]::new(785, 380)
    $panel.Visible  = $false
    $pnlContent.Controls.Add($panel)
}

Set-Step 0

# Welcome message in log
Write-LogCyan "  Qlik Open Lakehouse - AWS Deployment Wizard"
Write-LogGray "  Checking tools..."

# Auto-run tool check on startup
Run-ToolCheck

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
