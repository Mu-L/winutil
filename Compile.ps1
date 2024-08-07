param (
    [switch]$Debug,
    [switch]$Run,
    [switch]$SkipPreprocessing
)
$OFS = "`r`n"
$scriptname = "winutil.ps1"
$workingdir = $PSScriptRoot

# Variable to sync between runspaces
$sync = [Hashtable]::Synchronized(@{})
$sync.PSScriptRoot = $workingdir
$sync.configs = @{}

function Update-Progress {
    param (
        [Parameter(Mandatory, position=0)]
        [string]$StatusMessage,

        [Parameter(Mandatory, position=1)]
        [ValidateRange(0,100)]
        [int]$Percent,

        [Parameter(position=2)]
        [string]$Activity = "Compiling"
    )

    Write-Progress -Activity $Activity -Status $StatusMessage -PercentComplete $Percent
}

$header = @"
################################################################################################################
###                                                                                                          ###
### WARNING: This file is automatically generated DO NOT modify this file directly as it will be overwritten ###
###                                                                                                          ###
################################################################################################################
"@

if (-NOT $SkipPreprocessing) {
    Update-Progress "Pre-req: Running Preprocessor..." 0

    # Dot source the 'Invoke-Preprocessing' Function from 'tools/Invoke-Preprocessing.ps1' Script
    $preprocessingFilePath = ".\tools\Invoke-Preprocessing.ps1"
    . "$(($workingdir -replace ('\\$', '')) + '\' + ($preprocessingFilePath -replace ('\.\\', '')))"

    $excludedFiles = @('.\.git\', '.\.gitignore', '.\.gitattributes', '.\.github\CODEOWNERS', '.\LICENSE', "$preprocessingFilePath", '*.png', '*.exe')
    $msg = "Pre-req: Code Formatting"
    Invoke-Preprocessing -WorkingDir "$workingdir" -ExcludedFiles $excludedFiles -ProgressStatusMessage $msg
}

# Create the script in memory.
Update-Progress "Pre-req: Allocating Memory" 0
$script_content = [System.Collections.Generic.List[string]]::new()

Update-Progress "Adding: Header" 5
$script_content.Add($header)

Update-Progress "Adding: Version" 10
$script_content.Add($(Get-Content "$workingdir\scripts\start.ps1").replace('#{replaceme}',"$(Get-Date -Format yy.MM.dd)"))

Update-Progress "Adding: Functions" 20
Get-ChildItem "$workingdir\functions" -Recurse -File | ForEach-Object {
    $script_content.Add($(Get-Content $psitem.FullName))
    }
Update-Progress "Adding: Config *.json" 40
Get-ChildItem "$workingdir\config" | Where-Object {$psitem.extension -eq ".json"} | ForEach-Object {

    $json = (Get-Content $psitem.FullName).replace("'","''")

    # Replace every XML Special Character so it'll render correctly in final build
    # Only do so if json files has content to be displayed (for example the applications, tweaks, features json files)
        # Make an Array List containing every name at first level of Json File
        $jsonAsObject = $json | convertfrom-json
        $firstLevelJsonList = [System.Collections.ArrayList]::new()
        $jsonAsObject.PSObject.Properties.Name | ForEach-Object {$null = $firstLevelJsonList.Add($_)}
        # Note:
        #  Avoid using HTML Entity Codes, for example '&rdquo;' (stands for "Right Double Quotation Mark"),
        #  Use **HTML decimal/hex codes instead**, as using HTML Entity Codes will result in XML parse Error when running the compiled script.
        for ($i = 0; $i -lt $firstLevelJsonList.Count; $i += 1) {
            $firstLevelName = $firstLevelJsonList[$i]
            if ($jsonAsObject.$firstLevelName.content -ne $null) {
                $jsonAsObject.$firstLevelName.content = $jsonAsObject.$firstLevelName.content.replace('&','&#38;').replace('“','&#8220;').replace('”','&#8221;').replace("'",'&#39;').replace('<','&#60;').replace('>','&#62;').replace('—','&#8212;')
                $jsonAsObject.$firstLevelName.content = $jsonAsObject.$firstLevelName.content.replace('&#39;&#39;',"&#39;") # resolves the Double Apostrophe caused by the first replace function in the main loop
            }
            if ($jsonAsObject.$firstLevelName.description -ne $null) {
                $jsonAsObject.$firstLevelName.description = $jsonAsObject.$firstLevelName.description.replace('&','&#38;').replace('“','&#8220;').replace('”','&#8221;').replace("'",'&#39;').replace('<','&#60;').replace('>','&#62;').replace('—','&#8212;')
                $jsonAsObject.$firstLevelName.description = $jsonAsObject.$firstLevelName.description.replace('&#39;&#39;',"&#39;") # resolves the Double Apostrophe caused by the first replace function in the main loop
            }
        }

    # Add 'WPFInstall' as a prefix to every entry-name in 'applications.json' file
    if ($psitem.Name -eq "applications.json") {
        for ($i = 0; $i -lt $firstLevelJsonList.Count; $i += 1) {
            $appEntryName = $firstLevelJsonList[$i]
            $appEntryContent = $jsonAsObject.$appEntryName
            # Remove the entire app entry, so we could add it later with a different name
            $jsonAsObject.PSObject.Properties.Remove($appEntryName)
            # Add the app entry, but with a different name (WPFInstall + The App Entry Name)
            $jsonAsObject | Add-Member -MemberType NoteProperty -Name "WPFInstall$appEntryName" -Value $appEntryContent
        }
    }

    # The replace at the end is required, as without it the output of 'converto-json' will be somewhat weird for Multiline Strings
    # Most Notably is the scripts in some json files, making it harder for users who want to review these scripts, which're found in the compiled script
    $json = ($jsonAsObject | convertto-json -Depth 3).replace('\r\n',"`r`n")

    $sync.configs.$($psitem.BaseName) = $json | convertfrom-json
    $script_content.Add($(Write-output "`$sync.configs.$($psitem.BaseName) = '$json' `| convertfrom-json" ))
}

$xaml = (Get-Content "$workingdir\xaml\inputXML.xaml").replace("'","''")

# Dot-source the Get-TabXaml function
. "$workingdir\functions\private\Get-TabXaml.ps1"

Update-Progress "Building: Xaml " 75
$appXamlContent = Get-TabXaml "applications" 5
$tweaksXamlContent = Get-TabXaml "tweaks"
$featuresXamlContent = Get-TabXaml "feature"


Update-Progress "Adding: Xaml " 90
# Replace the placeholder in $inputXML with the content of inputApp.xaml
$xaml = $xaml -replace "{{InstallPanel_applications}}", $appXamlContent
$xaml = $xaml -replace "{{InstallPanel_tweaks}}", $tweaksXamlContent
$xaml = $xaml -replace "{{InstallPanel_features}}", $featuresXamlContent

$script_content.Add($(Write-output "`$inputXML =  '$xaml'"))

$script_content.Add($(Get-Content "$workingdir\scripts\main.ps1"))

if ($Debug) {
    Update-Progress "Writing debug files" 95
    $appXamlContent | Out-File -FilePath "$workingdir\xaml\inputApp.xaml" -Encoding ascii
    $tweaksXamlContent | Out-File -FilePath "$workingdir\xaml\inputTweaks.xaml" -Encoding ascii
    $featuresXamlContent | Out-File -FilePath "$workingdir\xaml\inputFeatures.xaml" -Encoding ascii
} else {
    Update-Progress "Removing temporary files" 99
    Remove-Item "$workingdir\xaml\inputApp.xaml" -ErrorAction SilentlyContinue
    Remove-Item "$workingdir\xaml\inputTweaks.xaml" -ErrorAction SilentlyContinue
    Remove-Item "$workingdir\xaml\inputFeatures.xaml" -ErrorAction SilentlyContinue
}

Set-Content -Path "$workingdir\$scriptname" -Value ($script_content -join "`r`n") -Encoding ascii
Write-Progress -Activity "Compiling" -Completed

Update-Progress -Activity "Validating" -StatusMessage "Checking winutil.ps1 Syntax" -Percent 0
try {
    $null = Get-Command -Syntax .\winutil.ps1
}
catch {
    Write-Warning "Syntax Validation for 'winutil.ps1' has failed"
    Write-Host "$($Error[0])" -ForegroundColor Red
}
Write-Progress -Activity "Validating" -Completed

if ($run) {
    try {
        Start-Process -FilePath "pwsh" -ArgumentList "$workingdir\$scriptname"
    } catch {
        Start-Process -FilePath "powershell" -ArgumentList "$workingdir\$scriptname"
    }

}
