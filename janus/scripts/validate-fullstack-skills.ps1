# ==============================================================================
# Janus Skill Validator
# L0 Frontmatter, Profile-YAML, Protocol Semantics & Release Closure Validator
# ==============================================================================
[CmdletBinding(DefaultParameterSetName = 'Validate')]
param(
    [Parameter(ParameterSetName = 'Validate')]
    [switch]$Validate = $true,

    [Parameter(ParameterSetName = 'SelfTest')]
    [switch]$SelfTest,

    [Parameter(ParameterSetName = 'RefreshManifest')]
    [switch]$RefreshManifest,

    [ValidateSet('Source', 'Release')]
    [string]$Mode = 'Source',

    [Parameter(ParameterSetName = 'Stage')]
    [string]$StageRelease
)

$ErrorActionPreference = 'Stop'

function Create-DiagResult([bool]$isValid, [string]$diagCode, [string]$path, [int]$line, [string]$message) {
    return [pscustomobject]@{
        IsValid        = $isValid
        DiagnosticCode = $diagCode
        Path           = $path
        Line           = $line
        Message        = $message
    }
}

function Ensure-TrailingSlash([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $path }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $altSep = [System.IO.Path]::AltDirectorySeparatorChar
    if (-not $path.EndsWith($sep.ToString()) -and -not $path.EndsWith($altSep.ToString())) {
        return $path + $sep
    }
    return $path
}

function Check-ReparsePointChain([string]$path, [bool]$checkAncestorsOnly = $false) {
    $curr = if ($checkAncestorsOnly) { Split-Path -Path $path -Parent } else { $path }
    while (-not [string]::IsNullOrWhiteSpace($curr)) {
        if (Test-Path -LiteralPath $curr) {
            try {
                $item = Get-Item -LiteralPath $curr -Force -ErrorAction Stop
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    return $curr
                }
            } catch {
                throw ("Failed to inspect attributes on: " + $curr + ". " + $_.Exception.Message)
            }
        }
        $parent = Split-Path -Path $curr -Parent
        if ($parent -eq $curr) { break }
        $curr = $parent
    }
    return $null
}

function Check-DirectoryHasAds([string]$dirPath) {
    $allTargets = @($dirPath) + @(Get-SafeTree $dirPath | ForEach-Object { $_.FullName })
    foreach ($target in $allTargets) {
        try {
            $streams = @(Get-Item -LiteralPath $target -Stream * -ErrorAction Stop)
            foreach ($s in $streams) {
                $sName = $s.Stream
                if ([string]::IsNullOrEmpty($sName)) { $sName = $s.StreamName }
                if (-not [string]::IsNullOrEmpty($sName) -and $sName -ne ':$DATA') {
                    return Create-DiagResult $false 'DIAG_NTFS_ADS_DETECTED' $target 0 ('Named stream detected: ' + $sName)
                }
            }
        } catch {
            # Fail-closed on stream inspection error
            return Create-DiagResult $false 'DIAG_NTFS_ADS_CHECK_FAILED' $target 0 ('Failed to enumerate streams on ' + $target + ': ' + $_.Exception.Message)
        }
    }
    return Create-DiagResult $true 'OK' $dirPath 0 'No ADS detected'
}

function Parse-RestrictedYamlScalar([string]$rawValue) {
    $trimmed = $rawValue.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return [pscustomobject]@{ IsValid = $false; Value = $null; Message = 'Scalar value is empty' }
    }

    if ($trimmed.StartsWith('"')) {
        $match = [System.Text.RegularExpressions.Regex]::Match(
            $trimmed,
            '^"(?<value>(?:[^"\\]|\\["\\/bfnrt]|\\u[0-9A-Fa-f]{4})*)"(?:[ \t]+#.*)?$'
        )
        if (-not $match.Success) {
            return [pscustomobject]@{ IsValid = $false; Value = $null; Message = 'Malformed or unterminated double-quoted scalar' }
        }
        Ensure-JsonHelper
        $decoded = [JsonSecurityHelper]::DecodeString('"' + $match.Groups['value'].Value + '"')
        return [pscustomobject]@{ IsValid = $true; Value = $decoded; Message = 'OK' }
    }

    if ($trimmed.StartsWith("'")) {
        $match = [System.Text.RegularExpressions.Regex]::Match(
            $trimmed,
            "^'(?<value>(?:[^']|'')*)'(?:[ \t]+#.*)?$"
        )
        if (-not $match.Success) {
            return [pscustomobject]@{ IsValid = $false; Value = $null; Message = 'Malformed or unterminated single-quoted scalar' }
        }
        return [pscustomobject]@{ IsValid = $true; Value = $match.Groups['value'].Value.Replace("''", "'"); Message = 'OK' }
    }

    if ($trimmed.Contains('"') -or $trimmed.Contains("'")) {
        return [pscustomobject]@{ IsValid = $false; Value = $null; Message = 'Quote characters in plain scalars are forbidden' }
    }
    $commentIndex = $trimmed.IndexOf(' #', [System.StringComparison]::Ordinal)
    if ($commentIndex -ge 0) {
        $trimmed = $trimmed.Substring(0, $commentIndex).TrimEnd()
    }
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -match '^[\-?:,\[\]{}#&*!|>@`%]' -or $trimmed -match ':([\s]|$)' -or $trimmed -match '[\x00-\x1f]') {
        return [pscustomobject]@{ IsValid = $false; Value = $null; Message = 'Unsupported plain scalar syntax' }
    }
    if ($trimmed -match '^(null|true|false|yes|no|on|off|~)$|^[+\-]?([0-9]|\.[0-9])|^[+\-]?\.(inf|nan)$') {
        return [pscustomobject]@{ IsValid = $false; Value = $null; Message = 'Implicitly typed or numeric-leading metadata must be quoted as a string' }
    }
    return [pscustomobject]@{ IsValid = $true; Value = $trimmed; Message = 'OK' }
}

function Read-Utf8NoBomText([string]$path) {
    $bytes = Read-BoundedBytes $path
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw ('UTF-8 BOM is forbidden: ' + $path)
    }
    return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
}

function Validate-SkillFrontmatter([string]$filePath) {
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return Create-DiagResult $false 'DIAG_FILE_NOT_FOUND' $filePath 0 ('File does not exist: ' + $filePath)
    }
    try { $rawBytes = Read-BoundedBytes $filePath } catch {
        return Create-DiagResult $false 'DIAG_FILE_SIZE_EXCEEDED' $filePath 0 $_.Exception.Message
    }
    if ($rawBytes.Length -eq 0) {
        return Create-DiagResult $false 'DIAG_FM_FILE_EMPTY' $filePath 0 'File is empty'
    }
    if ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
        return Create-DiagResult $false 'DIAG_UTF8_BOM_FORBIDDEN' $filePath 0 'UTF-8 BOM is forbidden'
    }
    try { $utf8Text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($rawBytes) }
    catch { return Create-DiagResult $false 'DIAG_UTF8_INVALID' $filePath 0 'Invalid UTF-8 byte sequence' }
    $lines = $utf8Text -split '\r?\n'
    if ($lines.Length -eq 0) {
        return Create-DiagResult $false 'DIAG_FM_NO_CONTENT' $filePath 0 'No content in file'
    }
    if ($lines[0] -ne '---') {
        return Create-DiagResult $false 'DIAG_FM_DELIMITER_INVALID' $filePath 1 ('First line must be exactly ---, found: ' + $lines[0])
    }
    $closingIndex = -1
    for ($i = 1; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -eq '---') {
            $closingIndex = $i
            break
        }
    }
    if ($closingIndex -eq -1) {
        return Create-DiagResult $false 'DIAG_FM_CLOSING_MISSING' $filePath 1 'Closing --- delimiter not found'
    }
    $fmLines = $lines[1..($closingIndex - 1)]
    $seenKeys = @{}
    $nameValue = $null
    $descValue = $null
    for ($idx = 0; $idx -lt $fmLines.Length; $idx++) {
        $lineNum = $idx + 2
        $l = $fmLines[$idx]
        if ([string]::IsNullOrWhiteSpace($l) -or $l.TrimStart().StartsWith('#')) { continue }
        if ($l -match '^[ \t]+\S') {
            return Create-DiagResult $false 'DIAG_FM_KEY_INDENTED' $filePath $lineNum ('Indented keys forbidden: ' + $l)
        }
        if ($l -match '^-[ 	]' -or $l -match '^[A-Za-z0-9_-]+[ 	]*:[ 	]*[|>&*]') {
            return Create-DiagResult $false 'DIAG_FM_COMPLEX_FORBIDDEN' $filePath $lineNum 'Complex YAML forbidden in frontmatter'
        }
        if ($l -match '^([A-Za-z0-9_-]+)[ 	]*:[ 	]*(.*)$') {
            $key = $matches[1]
            $scalar = Parse-RestrictedYamlScalar $matches[2]
            if (-not $scalar.IsValid) {
                return Create-DiagResult $false 'DIAG_FM_SCALAR_INVALID' $filePath $lineNum ($scalar.Message + ': ' + $l)
            }
            $val = $scalar.Value
            if ($seenKeys.ContainsKey($key)) {
                return Create-DiagResult $false 'DIAG_FM_DUPLICATE_KEY' $filePath $lineNum ('Duplicate frontmatter key: ' + $key)
            }
            $allowedFmKeys = @('name', 'description')
            if ($allowedFmKeys -notcontains $key) {
                return Create-DiagResult $false 'DIAG_FM_UNKNOWN_KEY' $filePath $lineNum ('Unknown frontmatter key forbidden: ' + $key)
            }
            $seenKeys[$key] = $val
            if ($key -eq 'name') { $nameValue = $val }
            if ($key -eq 'description') { $descValue = $val }
        } else {
            return Create-DiagResult $false 'DIAG_FM_SYNTAX_INVALID' $filePath $lineNum ('Unrecognized frontmatter syntax: ' + $l)
        }
    }
    if (-not $seenKeys.ContainsKey('name')) {
        return Create-DiagResult $false 'DIAG_FM_NAME_MISSING' $filePath 1 'Frontmatter missing name'
    }
    if ($nameValue -ne 'janus') {
        return Create-DiagResult $false 'DIAG_FM_NAME_INVALID' $filePath 1 ('Frontmatter name must be janus, found: ' + $nameValue)
    }
    if (-not $seenKeys.ContainsKey('description')) {
        return Create-DiagResult $false 'DIAG_FM_DESC_MISSING' $filePath 1 'Frontmatter missing description'
    }
    if ([string]::IsNullOrWhiteSpace($descValue)) {
        return Create-DiagResult $false 'DIAG_FM_DESC_EMPTY' $filePath 1 'Frontmatter description cannot be empty'
    }
    return Create-DiagResult $true 'OK' $filePath 0 'Valid frontmatter'
}

function Validate-OpenAiYaml([string]$filePath) {
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return Create-DiagResult $false 'DIAG_FILE_NOT_FOUND' $filePath 0 ('File does not exist: ' + $filePath)
    }
    try { $rawBytes = Read-BoundedBytes $filePath } catch {
        return Create-DiagResult $false 'DIAG_FILE_SIZE_EXCEEDED' $filePath 0 $_.Exception.Message
    }
    if ($rawBytes.Length -eq 0) {
        return Create-DiagResult $false 'DIAG_YAML_FILE_EMPTY' $filePath 0 'File is empty'
    }
    if ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
        return Create-DiagResult $false 'DIAG_UTF8_BOM_FORBIDDEN' $filePath 0 'UTF-8 BOM is forbidden'
    }
    try { $utf8Text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($rawBytes) }
    catch { return Create-DiagResult $false 'DIAG_UTF8_INVALID' $filePath 0 'Invalid UTF-8 byte sequence' }
    if ($utf8Text.Contains([char]9)) {
        return Create-DiagResult $false 'DIAG_YAML_TAB_INDENT' $filePath 0 'YAML forbids Tab characters'
    }
    $lines = $utf8Text -split '\r?\n'
    $seenTopKeys = @{}
    $seenChildKeys = @{}
    $section = ''
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $lineNum = $i + 1
        $l = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($l) -or $l.TrimStart().StartsWith('#')) { continue }
        if ($l -match '^([A-Za-z0-9_-]+)[ 	]*:[ 	]*(.*)$') {
            $topKey = $matches[1].Trim()
            $val = $matches[2].Trim()
            if ($topKey -cnotin @('interface', 'policy')) {
                return Create-DiagResult $false 'DIAG_YAML_UNKNOWN_TOP_KEY' $filePath $lineNum ('Unknown top-level key: ' + $topKey)
            }
            if ($seenTopKeys.ContainsKey($topKey)) {
                return Create-DiagResult $false 'DIAG_YAML_DUPLICATE_TOP_KEY' $filePath $lineNum ('Duplicate top-level key: ' + $topKey)
            }
            if (-not [string]::IsNullOrWhiteSpace($val) -and -not $val.StartsWith('#')) {
                return Create-DiagResult $false 'DIAG_YAML_INTERFACE_NOT_MAPPING' $filePath $lineNum 'interface key must be mapping header'
            }
            $seenTopKeys[$topKey] = $true
            $section = $topKey
            continue
        }
        if ($section -ne '' -and $l -match '^  ([A-Za-z0-9_-]+)[ 	]*:[ 	]*(.*)$') {
            $childKey = $matches[1].Trim()
            $raw = $matches[2].Trim()
            if ($section -ceq 'policy') {
                if ($childKey -cne 'allow_implicit_invocation') {
                    return Create-DiagResult $false 'DIAG_YAML_UNKNOWN_CHILD_KEY' $filePath $lineNum ('Unknown policy key: ' + $childKey)
                }
                if ($seenChildKeys.ContainsKey('policy.' + $childKey)) {
                    return Create-DiagResult $false 'DIAG_YAML_DUPLICATE_CHILD_KEY' $filePath $lineNum ('Duplicate policy key: ' + $childKey)
                }
                if ($raw -cmatch '^(false|true)(?:[ \t]+#.*)?$') {
                    $boolVal = $matches[1]
                    if ($boolVal -ceq 'true') {
                        return Create-DiagResult $false 'DIAG_YAML_POLICY_VALUE' $filePath $lineNum 'Janus requires explicit invocation (false)'
                    }
                } else {
                    return Create-DiagResult $false 'DIAG_YAML_POLICY_TYPE' $filePath $lineNum 'allow_implicit_invocation must be a boolean'
                }
                $seenChildKeys['policy.' + $childKey] = $false
                continue
            }
            $scalar = Parse-RestrictedYamlScalar $raw
            if (-not $scalar.IsValid) {
                return Create-DiagResult $false 'DIAG_YAML_SCALAR_INVALID' $filePath $lineNum ($scalar.Message + ': ' + $l)
            }
            $childVal = $scalar.Value
            if ($seenChildKeys.ContainsKey($childKey)) {
                return Create-DiagResult $false 'DIAG_YAML_DUPLICATE_CHILD_KEY' $filePath $lineNum ('Duplicate child key: ' + $childKey)
            }
            if ([string]::IsNullOrWhiteSpace($childVal) -or $childVal -eq '~' -or $childVal -eq 'null' -or $childVal -eq "''" -or $childVal -eq '""') {
                return Create-DiagResult $false 'DIAG_YAML_NULL_VALUE' $filePath $lineNum ('Key ' + $childKey + ' cannot have null or empty value')
            }
            $allowedChildKeys = @('display_name', 'short_description', 'default_prompt')
            if ($allowedChildKeys -notcontains $childKey) {
                return Create-DiagResult $false 'DIAG_YAML_UNKNOWN_CHILD_KEY' $filePath $lineNum ('Unknown interface key forbidden: ' + $childKey)
            }
            $seenChildKeys[$childKey] = $childVal
            continue
        }
        return Create-DiagResult $false 'DIAG_YAML_SYNTAX_ERROR' $filePath $lineNum ('Unexpected YAML line: ' + $l)
    }
    if (-not $seenTopKeys.ContainsKey('interface')) {
        return Create-DiagResult $false 'DIAG_YAML_INTERFACE_MISSING' $filePath 1 'Missing top-level interface'
    }
    foreach ($req in @('display_name', 'short_description', 'default_prompt')) {
        if (-not $seenChildKeys.ContainsKey($req)) {
            return Create-DiagResult $false 'DIAG_YAML_REQ_KEY_MISSING' $filePath 1 ('Missing required property under interface: ' + $req)
        }
    }
    if (-not $seenChildKeys.ContainsKey('policy.allow_implicit_invocation')) {
        return Create-DiagResult $false 'DIAG_YAML_POLICY_MISSING' $filePath 0 'Missing explicit invocation policy'
    }
    return Create-DiagResult $true 'OK' $filePath 0 'Valid openai.yaml Profile'
}

function Validate-ProtocolSemantics([string]$skillRoot) {
    try { Test-ProtocolModels $skillRoot }
    catch { return Create-DiagResult $false 'DIAG_PROTOCOL_MODEL_INVALID' $skillRoot 0 $_.Exception.Message }
    $requiredText = @(
        @{
            Path = 'SKILL.md'
            Values = @('渐进加载', 'references/control-plane.md', 'references/profile-tech-stack.md', 'references/subagents.md', 'references/verification.md')
        },
        @{
            Path = 'references/control-plane.md'
            Values = @('protocol_constants:', 'risk_score = max(I, D, C, R)', 'issue_registry:', 'REOPENED', 'Action Manifest', 'Recovery Capsule', '不可信数据', '升档与扩界', 'cb_same_strategy_failures', 'cb_lifetime_failures')
        },
        @{
            Path = 'references/mode-fast.md'
            Values = @('resume_supported: false', 'Final Sweep', '被测构建绑定')
        },
        @{
            Path = 'references/mode-standard.md'
            Values = @('docs/contract-<topic>.md', 'resume_supported: true', 'Event Log (append-only)', 'RECOVERY_UNCERTAIN', 'actual_write_set')
        },
        @{
            Path = 'references/mode-strict.md'
            Values = @('docs/fullstack/<topic>/', 'resume_supported: true', 'issue_registry:', 'review_exception', 'parent_event_ids', 'exception_digest', 'actual_write_set', 'INVALIDATED', 'Drift Detection', 'pre_gate4_write_snapshot')
        },
        @{
            Path = 'references/verification.md'
            Values = @('Subject-Scoped Digest', 'Freshness Binding', 'tested_build_identity', 'PARTIAL_DELIVERY_WITH_EXCEPTIONS', 'Final Sweep', '### R1/R2', '### R0')
        },
        @{
            Path = 'references/subagents.md'
            Values = @('references/control-plane.md', 'references/verification.md', 'review_exception: PENDING_GATE_1', 'base_revision', '不可信输出')
        },
        @{
            Path = 'references/profile-tech-stack.md'
            Values = @('references/control-plane.md', 'references/verification.md', '能力声明', '已加载产物')
        },
        @{
            Path = 'references/discovery.md'
            Values = @('references/control-plane.md', 'risk_scorecard:', 'Tier A', 'Tier B', 'Tier C')
        },
        @{
            Path = 'references/methods.md'
            Values = @('references/control-plane.md', 'REASSESSMENT_REQUIRED', 'PARTIAL_UNVERIFIED')
        }
    )

    foreach ($rule in $requiredText) {
        $path = Join-Path $skillRoot $rule.Path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return Create-DiagResult $false 'DIAG_PROTOCOL_FILE_MISSING' $path 0 ('Protocol file missing: ' + $rule.Path)
        }
        $text = Read-Utf8NoBomText $path
        foreach ($needle in $rule.Values) {
            if ($text.IndexOf($needle, [System.StringComparison]::Ordinal) -lt 0) {
                return Create-DiagResult $false 'DIAG_PROTOCOL_REQUIRED_TEXT_MISSING' $path 0 ('Required protocol marker missing: ' + $needle)
            }
        }
    }

    $controlPath = Join-Path $skillRoot 'references/control-plane.md'
    $controlText = Read-Utf8NoBomText $controlPath
    $protocolConstants = [ordered]@{
        cb_same_strategy_failures = '3'
        cb_lifetime_failures      = '5'
        test_defect_attempts_max  = '2'
        transient_retries_max     = '1'
        diagnostic_events_max     = '3'
        risk_r0_max               = '1'
        risk_r1_exact             = '2'
        risk_r2_min               = '3'
        final_required_outcome    = 'PASS'
        final_required_validity   = 'FINAL_VALID'
    }
    foreach ($constant in $protocolConstants.GetEnumerator()) {
        $pattern = '(?m)^[ ]{2}' + [System.Text.RegularExpressions.Regex]::Escape($constant.Key) + ':[ ]*(?<value>[^\r\n#]+)[ ]*$'
        $matches = [System.Text.RegularExpressions.Regex]::Matches($controlText, $pattern)
        if ($matches.Count -ne 1) {
            return Create-DiagResult $false 'DIAG_PROTOCOL_CONSTANT_CARDINALITY' $controlPath 0 ('Protocol constant must occur exactly once: ' + $constant.Key)
        }
        $actual = $matches[0].Groups['value'].Value.Trim()
        if ($actual -cne $constant.Value) {
            return Create-DiagResult $false 'DIAG_PROTOCOL_CONSTANT_MISMATCH' $controlPath 0 ('Protocol constant ' + $constant.Key + ' must be ' + $constant.Value + ', found ' + $actual)
        }
    }

    $markdownFiles = @(Get-SafeTree $skillRoot | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.md' })
    foreach ($md in $markdownFiles) {
        if ($md.FullName -eq $controlPath) { continue }
        $text = Read-Utf8NoBomText $md.FullName
        foreach ($constantName in $protocolConstants.Keys) {
            $definitionToken = [string]$constantName + ':'
            if ($text.IndexOf($definitionToken, [System.StringComparison]::Ordinal) -ge 0) {
                return Create-DiagResult $false 'DIAG_PROTOCOL_CONSTANT_DUPLICATED' $md.FullName 0 ('Protocol constant may only be defined in control-plane.md: ' + $definitionToken)
            }
        }
    }

    $legacyTokens = @(
        ('BLOCKED_' + 'REASSESSMENT'),
        ('candidate_' + 'code_hash'),
        ('candidate_' + 'package_hash'),
        ('subject_' + 'fingerprint'),
        ('绝不进行第 ' + '4 次尝试'),
        ('当前 epoch 内尝试次数达到 ' + '5 次'),
        ('双' + '计数器')
    )
    foreach ($md in $markdownFiles) {
        $text = Read-Utf8NoBomText $md.FullName
        foreach ($legacy in $legacyTokens) {
            if ($text.IndexOf($legacy, [System.StringComparison]::Ordinal) -ge 0) {
                return Create-DiagResult $false 'DIAG_PROTOCOL_LEGACY_TOKEN' $md.FullName 0 ('Legacy or conflicting protocol token found: ' + $legacy)
            }
        }
    }

    $packageReferencePattern = '(?<![A-Za-z0-9_.-])((?:references|scripts|agents)/[A-Za-z0-9._/-]+)'
    foreach ($md in $markdownFiles) {
        $text = Read-Utf8NoBomText $md.FullName
        foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($text, $packageReferencePattern)) {
            $relativePath = $match.Groups[1].Value
            if ($Global:JanusWhitelist14 -notcontains $relativePath) {
                return Create-DiagResult $false 'DIAG_PROTOCOL_REFERENCE_UNLISTED' $md.FullName 0 ('Reference is outside the 14-file closure: ' + $relativePath)
            }
            $target = Join-Path $skillRoot $relativePath
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                return Create-DiagResult $false 'DIAG_PROTOCOL_REFERENCE_DANGLING' $md.FullName 0 ('Dangling package reference: ' + $relativePath)
            }
        }
    }

    $referenceTargets = @($Global:JanusWhitelist14 | Where-Object { $_.StartsWith('references/', [System.StringComparison]::Ordinal) })
    foreach ($referenceTarget in $referenceTargets) {
        $incoming = 0
        foreach ($md in $markdownFiles) {
            $relativeMd = $md.FullName.Substring($skillRoot.Length + 1).Replace([char]92, [char]47)
            if ($relativeMd -eq $referenceTarget) { continue }
            $text = Read-Utf8NoBomText $md.FullName
            if ($text.IndexOf($referenceTarget, [System.StringComparison]::Ordinal) -ge 0) {
                $incoming++
            }
        }
        if ($incoming -eq 0) {
            return Create-DiagResult $false 'DIAG_PROTOCOL_REFERENCE_ORPHAN' (Join-Path $skillRoot $referenceTarget) 0 ('Reference has no incoming context pointer: ' + $referenceTarget)
        }
    }

    $yamlPath = Join-Path $skillRoot 'agents/openai.yaml'
    $yamlText = Read-Utf8NoBomText $yamlPath
    $promptMatch = [System.Text.RegularExpressions.Regex]::Match($yamlText, '(?m)^  default_prompt:[ ]*"(?<value>[^"]+)"[ ]*\r?$')
    if (-not $promptMatch.Success) {
        return Create-DiagResult $false 'DIAG_PROTOCOL_DEFAULT_PROMPT_INVALID' $yamlPath 0 'default_prompt must be a quoted one-line string'
    }
    $promptValue = $promptMatch.Groups['value'].Value
    if ($promptValue.IndexOf('$janus', [System.StringComparison]::Ordinal) -lt 0 -or $promptValue -notmatch '[一-龥]') {
        return Create-DiagResult $false 'DIAG_PROTOCOL_DEFAULT_PROMPT_NOT_CHINESE' $yamlPath 0 'default_prompt must be Chinese and explicitly mention $janus'
    }

    return Create-DiagResult $true 'OK' $skillRoot 0 'Finite protocol model, markers and reference closure validated; natural-language consistency is not proven'
}

function Get-YamlModelBlock([string]$text, [string]$key) {
    $fence = [string]([char]96) * 3
    $blocks = @([regex]::Matches($text, ('(?m)^' + $fence + 'yaml[ \t]*\r?\n(?<body>[\s\S]*?)^' + $fence + '[ \t]*\r?$')) |
        Where-Object { $_.Groups['body'].Value -match ('(?m)^' + [regex]::Escape($key) + ':') })
    if ($blocks.Count -ne 1) { throw ('Expected exactly one fenced yaml model: ' + $key) }
    return $blocks[0].Groups['body'].Value
}

function Get-ModelAssignment([string]$block, [string]$key, [int]$indent = 0) {
    $pattern = '(?m)^ {' + $indent + '}' + [regex]::Escape($key) + ':[ \t]*(?<value>[^\r\n]*)\r?$'
    $found = [regex]::Matches($block, $pattern)
    if ($found.Count -ne 1) { throw ('Expected unique model assignment: ' + $key) }
    return $found[0].Groups['value'].Value.Trim()
}

function Test-ProtocolModels([string]$root) {
    $control = Read-Utf8NoBomText (Join-Path $root 'references/control-plane.md')
    $rules = Get-YamlModelBlock $control 'protocol_rules'
    $expected = [ordered]@{
        cb_priority = 'LIFETIME_FIRST'
        lifetime_reset_on_resume = 'false'
        partial_delivery_requires_acceptance = 'true'
        gate_requires_valid_parent = 'true'
        source_write_requires_behavior_frozen = 'true'
        unknown_history_policy = 'PRESERVE_AND_RECONCILE'
        final_sweep_reuse = 'STABLE_AND_COMPLETE'
    }
    $lines = @($rules -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '^[ ]*#' })
    if ($lines.Count -ne 8 -or $lines[0] -cne 'protocol_rules:') { throw 'protocol_rules requires one mapping and exactly seven assignments' }
    foreach ($rule in $expected.GetEnumerator()) {
        # Exact unquoted boolean/enum tokens enforce the intended restricted YAML types.
        if ((Get-ModelAssignment $rules $rule.Key 2) -cne $rule.Value) { throw ('Invalid typed protocol rule: ' + $rule.Key) }
    }
    $r1 = Get-YamlModelBlock (Read-Utf8NoBomText (Join-Path $root 'references/mode-standard.md')) 'janus_dossier_schema'
    if ((Get-ModelAssignment $r1 'janus_dossier_schema') -cne '"2.2"') { throw 'R1 dossier schema must be string 2.2' }
    $app = Parse-RestrictedYamlScalar (Get-ModelAssignment $r1 'interface_applicability')
    $contract = Parse-RestrictedYamlScalar (Get-ModelAssignment $r1 'interface_contract_status')
    $behavior = Parse-RestrictedYamlScalar (Get-ModelAssignment $r1 'behavior_contract_status')
    if (-not $app.IsValid -or -not $contract.IsValid -or -not $behavior.IsValid -or $behavior.Value -cne 'FROZEN' -or
        -not (($app.Value -ceq 'IN_SCOPE' -and $contract.Value -ceq 'FROZEN') -or ($app.Value -ceq 'NOT_APPLICABLE' -and $contract.Value -ceq 'NOT_APPLICABLE'))) {
        throw 'R1 interface applicability/freeze and behavior freeze disagree'
    }
    $r2 = Get-YamlModelBlock (Read-Utf8NoBomText (Join-Path $root 'references/mode-strict.md')) 'gate_approval_records'
    if ((Get-ModelAssignment $r2 'revision') -cnotmatch '^2(?:[ \t]+#.*)?$') { throw 'Gate example revision must be integer 2' }
    for ($gate = 1; $gate -le 5; $gate++) {
        $sections = [regex]::Matches($r2, ('(?ms)^  gate_' + $gate + ':\r?\n(?<body>.*?)(?=^  gate_|^\S|\z)'))
        if ($sections.Count -ne 1) { throw ('Gate example missing/duplicated: ' + $gate) }
        $section = $sections[0].Groups['body'].Value
        $status = Parse-RestrictedYamlScalar (Get-ModelAssignment $section 'effective_status' 4)
        $eligibility = Parse-RestrictedYamlScalar (Get-ModelAssignment $section 'eligibility' 4)
        $expectedStatus = if ($gate -eq 1) { 'VALID' } else { 'NOT_REACHED' }
        $expectedEligibility = if ($gate -le 2) { 'ELIGIBLE' } else { 'BLOCKED_BY_UPSTREAM' }
        if (-not $status.IsValid -or -not $eligibility.IsValid -or $status.Value -cne $expectedStatus -or $eligibility.Value -cne $expectedEligibility) {
            throw ('Gate example status/eligibility mismatch: ' + $gate)
        }
        if ($gate -eq 1) {
            if ($section -notmatch '(?m)^    events:' -or $section -notmatch '(?m)^      - event_id:' -or $section -notmatch 'type: REQUESTED' -or $section -notmatch 'type: APPROVED' -or $section -notmatch 'parent_event_ids: \[evt-g1-01\]') {
                throw 'Gate 1 example must derive VALID from REQUESTED and APPROVED events'
            }
        } else {
            if ($section -notmatch '(?m)^    events: \[\]') {
                throw ('Unreached gate example must keep an empty events list: ' + $gate)
            }
        }
    }
    $skill = Read-Utf8NoBomText (Join-Path $root 'SKILL.md')
    foreach ($mode in @('R0', 'R1', 'R2')) {
        $rows = [regex]::Matches($skill, ('(?m)^\| ' + $mode + ' \|(?<required>[^|]*)\|\r?$'))
        if ($rows.Count -ne 1 -or -not $rows[0].Groups['required'].Value.Contains('references/verification.md')) {
            throw ('Required route must include verification: ' + $mode)
        }
        if ($rows[0].Groups['required'].Value.Contains('references/subagents.md')) { throw 'Subagents must remain conditional' }
    }
    if ($skill -notmatch '(?m)^启动时合并读取[^\r\n]*references/control-plane\.md' -or
        $skill -notmatch '(?m)^\| 实际派发子 Agent[^\r\n]*references/subagents\.md') {
        throw 'Startup control plane and conditional subagents routes are required'
    }
}

function Ensure-JsonHelper {
    if (-not ([System.Management.Automation.PSTypeName]'JsonSecurityHelper').Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;

public static class JsonSecurityHelper {
    public static string DecodeString(string text) {
        int index = 0;
        return ReadString(text, ref index);
    }
    public static string CheckDuplicateKeys(string jsonText) {
        Stack<HashSet<string>> stack = new Stack<HashSet<string>>();
        for (int i = 0; i < jsonText.Length; i++) {
            char current = jsonText[i];
            if (current == '{') {
                stack.Push(new HashSet<string>(StringComparer.OrdinalIgnoreCase));
            } else if (current == '}') {
                if (stack.Count > 0) stack.Pop();
            } else if (current == '"') {
                string token = ReadString(jsonText, ref i);
                int lookahead = i + 1;
                while (lookahead < jsonText.Length && char.IsWhiteSpace(jsonText[lookahead])) lookahead++;
                if (lookahead < jsonText.Length && jsonText[lookahead] == ':' && stack.Count > 0) {
                    HashSet<string> currentObject = stack.Peek();
                    if (!currentObject.Add(token)) return token;
                }
            }
        }
        return null;
    }

    private static string ReadString(string text, ref int index) {
        StringBuilder value = new StringBuilder();
        for (index = index + 1; index < text.Length; index++) {
            char current = text[index];
            if (current == '"') return value.ToString();
            if (current < 0x20) throw new FormatException("Control character in JSON string");
            if (current != '\\') {
                value.Append(current);
                continue;
            }
            if (++index >= text.Length) throw new FormatException("Unterminated JSON escape");
            char escaped = text[index];
            switch (escaped) {
                case '"': value.Append('"'); break;
                case '\\': value.Append('\\'); break;
                case '/': value.Append('/'); break;
                case 'b': value.Append('\b'); break;
                case 'f': value.Append('\f'); break;
                case 'n': value.Append('\n'); break;
                case 'r': value.Append('\r'); break;
                case 't': value.Append('\t'); break;
                case 'u':
                    if (index + 4 >= text.Length) throw new FormatException("Incomplete JSON unicode escape");
                    int codePoint;
                    if (!Int32.TryParse(text.Substring(index + 1, 4), System.Globalization.NumberStyles.HexNumber, System.Globalization.CultureInfo.InvariantCulture, out codePoint)) {
                        throw new FormatException("Invalid JSON unicode escape");
                    }
                    value.Append((char)codePoint);
                    index += 4;
                    break;
                default: throw new FormatException("Invalid JSON escape");
            }
        }
        throw new FormatException("Unterminated JSON string");
    }
}
"@
    }
}

function Check-JsonNoDuplicateKeys([string]$jsonText, [string]$filePath) {
    Ensure-JsonHelper
    try {
        $dup = [JsonSecurityHelper]::CheckDuplicateKeys($jsonText)
        if (-not [string]::IsNullOrEmpty($dup)) {
            return Create-DiagResult $false 'DIAG_JSON_DUPLICATE_KEY' $filePath 0 ('Duplicate JSON key: ' + $dup)
        }
        return Create-DiagResult $true 'OK' $filePath 0 'No duplicate JSON keys'
    } catch {
        return Create-DiagResult $false 'DIAG_MANIFEST_JSON_SYNTAX' $filePath 0 ('Invalid JSON syntax: ' + $_.Exception.Message)
    }
}

function Validate-ManifestPathSafe([string]$path, [string]$manifestPath) {
    if ($path -cmatch '[<>"|?*\x00-\x1f]') { return Create-DiagResult $false 'DIAG_MANIFEST_PATH_INVALID' $manifestPath 0 'Invalid Windows path characters' }
    if ([string]::IsNullOrWhiteSpace($path)) {
        return Create-DiagResult $false 'DIAG_MANIFEST_PATH_INVALID' $manifestPath 0 'Path cannot be empty'
    }
    if ($path.StartsWith('/') -or $path.EndsWith('/')) {
        return Create-DiagResult $false 'DIAG_MANIFEST_PATH_INVALID' $manifestPath 0 ('Leading or trailing slash forbidden: ' + $path)
    }
    if ($path.Contains([char]92)) {
        return Create-DiagResult $false 'DIAG_MANIFEST_PATH_INVALID' $manifestPath 0 ('Backslashes forbidden: ' + $path)
    }
    if ($path.Contains(':')) {
        return Create-DiagResult $false 'DIAG_MANIFEST_PATH_INVALID' $manifestPath 0 ('Colons forbidden: ' + $path)
    }
    $segments = $path -split '/'
    $dosDevices = @('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')
    foreach ($seg in $segments) {
        if ([string]::IsNullOrEmpty($seg)) {
            return Create-DiagResult $false 'DIAG_MANIFEST_PATH_INVALID' $manifestPath 0 ('Empty segment forbidden in path: ' + $path)
        }
        if ($seg -eq '..') {
            return Create-DiagResult $false 'DIAG_MANIFEST_PATH_TRAVERSAL' $manifestPath 0 ('Path traversal .. forbidden: ' + $path)
        }
        if ($seg -eq '.') {
            return Create-DiagResult $false 'DIAG_MANIFEST_PATH_INVALID' $manifestPath 0 ('. segment forbidden: ' + $path)
        }
        if ($seg.EndsWith(' ') -or $seg.EndsWith('.')) {
            return Create-DiagResult $false 'DIAG_MANIFEST_PATH_INVALID' $manifestPath 0 ('Trailing dot/space forbidden: ' + $path)
        }
        $baseName = ($seg -split '\.')[0].ToUpperInvariant()
        if ($dosDevices -contains $baseName) {
            return Create-DiagResult $false 'DIAG_MANIFEST_PATH_INVALID' $manifestPath 0 ('DOS device name forbidden: ' + $path)
        }
    }
    return Create-DiagResult $true 'OK' $manifestPath 0 'Path safe'
}

function Get-OrdinalPathSortedEntries([object[]]$entries) {
    $entryMap = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $entries) {
        $path = [string]$entry.path
        if ($entryMap.ContainsKey($path)) {
            throw ('Duplicate entry path cannot be sorted: ' + $path)
        }
        $entryMap.Add($path, $entry)
        $paths.Add($path)
    }
    $pathArray = $paths.ToArray()
    [System.Array]::Sort($pathArray, [System.StringComparer]::Ordinal)
    $ordered = New-Object System.Collections.Generic.List[object]
    foreach ($path in $pathArray) {
        $ordered.Add($entryMap[$path])
    }
    return $ordered.ToArray()
}

function Compute-PayloadDigest([object[]]$shipEntries, [switch]$IncludeManifest) {
    # 13 ship:true non-manifest entries sorted Ordinal by path
    $payloadEntries = @($shipEntries | Where-Object { $IncludeManifest -or $_.path -ne 'release-manifest.json' })
    $sorted = @(Get-OrdinalPathSortedEntries $payloadEntries)
    $digestStream = New-Object System.Collections.Generic.List[byte]
    $shaAlgo = [System.Security.Cryptography.SHA256]::Create()
    foreach ($e in $sorted) {
        $pBytes = [System.Text.Encoding]::UTF8.GetBytes($e.path)
        $hBytes = [System.Text.Encoding]::UTF8.GetBytes($e.sha256.ToLowerInvariant())
        $digestStream.AddRange($pBytes)
        $digestStream.Add([byte]0)
        $digestStream.AddRange($hBytes)
        $digestStream.Add([byte]10)
    }
    $computedHash = [BitConverter]::ToString($shaAlgo.ComputeHash($digestStream.ToArray())).Replace('-', '').ToLowerInvariant()
    $shaAlgo.Dispose()
    return $computedHash
}

$Global:JanusWhitelist14 = @(
    'SKILL.md',
    'README.md',
    'release-manifest.json',
    'agents/openai.yaml',
    'scripts/validate-fullstack-skills.ps1',
    'references/control-plane.md',
    'references/discovery.md',
    'references/methods.md',
    'references/mode-fast.md',
    'references/mode-standard.md',
    'references/mode-strict.md',
    'references/profile-tech-stack.md',
    'references/subagents.md',
    'references/verification.md'
)

$Global:JanusAllowedDirs = @('agents', 'scripts', 'references')

function Validate-ReleaseManifestJson([string]$manifestPath, [string]$skillRoot, [string]$mode) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return Create-DiagResult $false 'DIAG_MANIFEST_MISSING' $manifestPath 0 'release-manifest.json not found'
    }
    $manifestBytes = Read-BoundedBytes $manifestPath
    if ($manifestBytes.Length -ge 3 -and $manifestBytes[0] -eq 0xEF -and $manifestBytes[1] -eq 0xBB -and $manifestBytes[2] -eq 0xBF) {
        return Create-DiagResult $false 'DIAG_UTF8_BOM_FORBIDDEN' $manifestPath 0 'UTF-8 BOM is forbidden'
    }
    try { $rawText = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($manifestBytes) }
    catch { return Create-DiagResult $false 'DIAG_UTF8_INVALID' $manifestPath 0 'Invalid UTF-8 byte sequence' }
    $dupCheck = Check-JsonNoDuplicateKeys $rawText $manifestPath
    if (-not $dupCheck.IsValid) {
        return $dupCheck
    }
    try {
        $manifest = $rawText | ConvertFrom-Json
    } catch {
        return Create-DiagResult $false 'DIAG_MANIFEST_JSON_SYNTAX' $manifestPath 0 ('Invalid JSON: ' + $_.Exception.Message)
    }

    # Strict Schema 2.0.0 Checks for pure 14-file package
    foreach ($key in @('schema_version', 'skill_name', 'payload_digest')) {
        if ($manifest.$key -isnot [string]) { return Create-DiagResult $false 'DIAG_MANIFEST_TYPE_INVALID' $manifestPath 0 ('Required string: ' + $key) }
    }
    foreach ($key in @('total_files', 'ship_true_count', 'ship_false_count')) {
        if ($manifest.$key -isnot [int] -and $manifest.$key -isnot [long]) { return Create-DiagResult $false 'DIAG_MANIFEST_TYPE_INVALID' $manifestPath 0 ('Required integer: ' + $key) }
    }
    if ($manifest.files -isnot [array] -or $manifest.payload_digest -cnotmatch '^[0-9a-f]{64}$') {
        return Create-DiagResult $false 'DIAG_MANIFEST_TYPE_INVALID' $manifestPath 0 'files must be an array and payload_digest a lowercase SHA256'
    }
    if ($manifest.schema_version -ne '2.0.0') {
        return Create-DiagResult $false 'DIAG_MANIFEST_SCHEMA_INVALID' $manifestPath 1 'schema_version must be 2.0.0'
    }
    if ($manifest.skill_name -ne 'janus') {
        return Create-DiagResult $false 'DIAG_MANIFEST_SKILL_NAME_INVALID' $manifestPath 1 ('skill_name must be janus, found: ' + $manifest.skill_name)
    }
    if ([string]::IsNullOrWhiteSpace($manifest.payload_digest) -or $manifest.payload_digest.Length -ne 64) {
        return Create-DiagResult $false 'DIAG_MANIFEST_PAYLOAD_DIGEST_INVALID' $manifestPath 1 'payload_digest must be 64-char sha256'
    }

    $allowedTopKeys = @('schema_version', 'skill_name', 'total_files', 'ship_true_count', 'ship_false_count', 'payload_digest', 'files')
    $manifestProperties = $manifest.PSObject.Properties | ForEach-Object { $_.Name }
    foreach ($prop in $manifestProperties) {
        if ($allowedTopKeys -notcontains $prop) {
            return Create-DiagResult $false 'DIAG_MANIFEST_UNKNOWN_TOP_KEY' $manifestPath 1 ('Unknown top-level key forbidden: ' + $prop)
        }
    }

    if ($manifest.total_files -ne 14 -or $manifest.ship_true_count -ne 14 -or $manifest.ship_false_count -ne 0) {
        return Create-DiagResult $false 'DIAG_MANIFEST_COUNT_MISMATCH' $manifestPath 1 'Manifest counts must be 14 total, 14 ship:true, 0 ship:false'
    }

    $manifestMap = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    $shipList = New-Object System.Collections.Generic.List[object]
    $allowedFileKeys = @('path', 'category', 'ship', 'sha256')

    foreach ($entry in $manifest.files) {
        foreach ($key in @('path', 'category', 'sha256')) {
            if ($entry.$key -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.$key)) {
                return Create-DiagResult $false 'DIAG_MANIFEST_TYPE_INVALID' $manifestPath 0 ('Required nonempty entry string: ' + $key)
            }
        }
        $entryProps = $entry.PSObject.Properties | ForEach-Object { $_.Name }
        foreach ($ep in $entryProps) {
            if ($allowedFileKeys -notcontains $ep) {
                return Create-DiagResult $false 'DIAG_MANIFEST_UNKNOWN_ENTRY_KEY' $manifestPath 0 ('Unknown file entry key: ' + $ep)
            }
        }
        $safePathRes = Validate-ManifestPathSafe $entry.path $manifestPath
        if (-not $safePathRes.IsValid) { return $safePathRes }

        # Check whitelist
        if ($Global:JanusWhitelist14 -cnotcontains $entry.path) {
            return Create-DiagResult $false 'DIAG_MANIFEST_PATH_NOT_IN_WHITELIST' $manifestPath 0 ('Path not in 14 whitelist: ' + $entry.path)
        }

        if ($manifestMap.ContainsKey($entry.path)) {
            return Create-DiagResult $false 'DIAG_MANIFEST_DUPLICATE_ENTRY' $manifestPath 0 ('Duplicate path in manifest: ' + $entry.path)
        }
        if ($entry.ship -isnot [bool] -or $entry.ship -ne $true) {
            return Create-DiagResult $false 'DIAG_MANIFEST_SHIP_TYPE_INVALID' $manifestPath 0 ('ship property must be true: ' + $entry.path)
        }
        if ($entry.path -eq 'release-manifest.json') {
            if ($entry.sha256 -ne 'self-manifest-schema-only') {
                return Create-DiagResult $false 'DIAG_MANIFEST_SELF_SENTINEL_INVALID' $manifestPath 0 'release-manifest.json sha256 must be self-manifest-schema-only'
            }
        } else {
            if ($entry.sha256 -notmatch '^[0-9a-f]{64}$') {
                return Create-DiagResult $false 'DIAG_MANIFEST_HASH_SYNTAX_INVALID' $manifestPath 0 ('Invalid sha256 hash syntax: ' + $entry.path)
            }
        }
        $manifestMap[$entry.path] = $entry
        $shipList.Add($entry)
    }

    if ($manifestMap.Count -ne 14) {
        return Create-DiagResult $false 'DIAG_MANIFEST_COUNT_MISMATCH' $manifestPath 1 'Manifest must contain exactly 14 files'
    }

    # Reparse Point checks in root
    $reparseInRoot = Check-ReparsePointChain $skillRoot
    if (-not [string]::IsNullOrEmpty($reparseInRoot)) {
        return Create-DiagResult $false 'DIAG_REPARSE_POINT_FORBIDDEN' $reparseInRoot 0 ('Reparse point forbidden: ' + $reparseInRoot)
    }

    # Check directory structure: only allowed subdirectories allowed
    try { $tree = @(Get-SafeTree $skillRoot) } catch { return Create-DiagResult $false 'DIAG_REPARSE_POINT_FORBIDDEN' $skillRoot 0 $_.Exception.Message }
    $diskDirs = @($tree | Where-Object { $_.PSIsContainer })
    foreach ($dd in $diskDirs) {
        $relD = $dd.FullName.Substring($skillRoot.Length + 1).Replace([char]92, [char]47)
        if ($Global:JanusAllowedDirs -cnotcontains $relD) {
            return Create-DiagResult $false 'DIAG_MANIFEST_UNEXPECTED_DIRECTORY' $dd.FullName 0 ('Unexpected directory forbidden: ' + $relD)
        }
    }

    $diskFiles = @($tree | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName)
    if ($diskFiles.Count -ne 14) {
        return Create-DiagResult $false 'DIAG_MANIFEST_DISK_COUNT_MISMATCH' $manifestPath 1 ('Directory has ' + $diskFiles.Count + ' files, expected 14')
    }

    $verifiedShipEntries = New-Object System.Collections.Generic.List[object]
    Ensure-FilesystemHelper
    $snapshotEntries = New-Object 'System.Collections.Generic.List[JanusFrozenEntry]'
    [long]$snapshotSize = 0

    foreach ($df in $diskFiles) {
        if ($df.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            return Create-DiagResult $false 'DIAG_REPARSE_POINT_FORBIDDEN' $df.FullName 0 'Reparse point forbidden'
        }
        $rel = $df.FullName.Substring($skillRoot.Length + 1).Replace([char]92, [char]47)
        if (-not $manifestMap.ContainsKey($rel)) {
            return Create-DiagResult $false 'DIAG_MANIFEST_UNLISTED_FILE' $df.FullName 0 ('Unlisted file: ' + $rel)
        }
        $entry = $manifestMap[$rel]
        $bytes = if ($rel -ceq 'release-manifest.json') { $manifestBytes } else { Read-BoundedBytes $df.FullName }
        $snapshotSize += $bytes.Length
        if ($snapshotSize -gt 32MB) { return Create-DiagResult $false 'DIAG_SNAPSHOT_SIZE_EXCEEDED' $df.FullName 0 'Snapshot exceeds 32 MiB total byte limit' }
        $sha = Get-BytesHash $bytes
        $snapshotEntries.Add((New-Object JanusFrozenEntry($rel, $entry.category, $sha, [Convert]::ToBase64String($bytes))))
        if ($rel -cne 'release-manifest.json') {
            if ($sha -ne $entry.sha256.ToLowerInvariant()) {
                $diag = if ($mode -eq 'Release') { 'DIAG_RELEASE_HASH_MISMATCH' } else { 'DIAG_MANIFEST_HASH_MISMATCH' }
                return Create-DiagResult $false $diag $df.FullName 0 ('Hash mismatch for ' + $rel + ': disk=' + $sha + ', manifest=' + $entry.sha256)
            }
            $verifiedShipEntries.Add($entry)
        }
    }

    $expectedPayloadDigest = Compute-PayloadDigest $verifiedShipEntries
    if ($manifest.payload_digest.ToLowerInvariant() -ne $expectedPayloadDigest) {
        $diag = if ($mode -eq 'Release') { 'DIAG_RELEASE_PAYLOAD_DIGEST_MISMATCH' } else { 'DIAG_MANIFEST_PAYLOAD_DIGEST_MISMATCH' }
        return Create-DiagResult $false $diag $manifestPath 1 ('payload_digest mismatch: declared=' + $manifest.payload_digest + ', calculated=' + $expectedPayloadDigest)
    }

    # Strict ADS inspection
    $adsCheck = Check-DirectoryHasAds $skillRoot
    if (-not $adsCheck.IsValid) {
        return $adsCheck
    }

    $result = Create-DiagResult $true 'OK' $manifestPath 0 'Manifest validated successfully'
    $result | Add-Member NoteProperty Snapshot ($snapshotEntries.AsReadOnly())
    $result | Add-Member NoteProperty payload_digest $expectedPayloadDigest
    $result | Add-Member NoteProperty package_digest (Compute-PayloadDigest $snapshotEntries.ToArray() -IncludeManifest)
    return $result
}

function Validate-JanusPackage([string]$manifestPath, [string]$skillRoot, [string]$mode) {
    try { [void]@(Get-SafeTree $skillRoot) } catch { return Create-DiagResult $false 'DIAG_REPARSE_POINT_FORBIDDEN' $skillRoot 0 $_.Exception.Message }
    foreach ($relativePath in $Global:JanusWhitelist14) {
        $path = Join-Path $skillRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return Create-DiagResult $false 'DIAG_PACKAGE_REQUIRED_FILE_MISSING' $path 0 ('Required package file missing: ' + $relativePath)
        }
    }

    foreach ($relativePath in $Global:JanusWhitelist14) {
        $path = Join-Path $skillRoot $relativePath
        try {
            $bytes = Read-BoundedBytes $path
            $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            if ($relativePath.EndsWith('.ps1')) {
                if (-not $hasBom) { return Create-DiagResult $false 'DIAG_PS1_BOM_REQUIRED' $path 0 'PowerShell 5.1 script requires UTF-8 BOM' }
            } elseif ($hasBom) { return Create-DiagResult $false 'DIAG_UTF8_BOM_FORBIDDEN' $path 0 'UTF-8 BOM is forbidden for Markdown/JSON/YAML' }
            [void](New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
        } catch {
            $diag = if ($_.Exception.Message -match '8 MiB snapshot limit') { 'DIAG_FILE_SIZE_EXCEEDED' } else { 'DIAG_ENCODING_READ_FAILED' }
            return Create-DiagResult $false $diag $path 0 $_.Exception.Message
        }
    }

    $frontmatter = Validate-SkillFrontmatter (Join-Path $skillRoot 'SKILL.md')
    if (-not $frontmatter.IsValid) { return $frontmatter }

    $profile = Validate-OpenAiYaml (Join-Path $skillRoot 'agents/openai.yaml')
    if (-not $profile.IsValid) { return $profile }

    $protocol = Validate-ProtocolSemantics $skillRoot
    if (-not $protocol.IsValid) { return $protocol }

    return Validate-ReleaseManifestJson $manifestPath $skillRoot $mode
}

function Ensure-FilesystemHelper {
    if (([System.Management.Automation.PSTypeName]'JanusFs').Type) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public sealed class JanusFrozenEntry {
    public string path { get; private set; }
    public string category { get; private set; }
    public string sha256 { get; private set; }
    public string ContentBase64 { get; private set; }
    public JanusFrozenEntry(string p, string c, string h, string b) {
        path = p; category = c; sha256 = h; ContentBase64 = b;
    }
}
public static class JanusFs {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string p, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle h, out Info info);
    [StructLayout(LayoutKind.Sequential)]
    struct Info {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct SecurityAttributes { public int Length; public IntPtr Descriptor; public int Inherit; }
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string s, uint revision, out IntPtr sd, out uint size);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateDirectory(string path, ref SecurityAttributes sa);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
    public static SafeFileHandle HoldDirectory(string path) {
        // No FILE_SHARE_DELETE; OPEN_REPARSE_POINT inspects the object, never its target.
        SafeFileHandle h = CreateFile(path, 0x81, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (h.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), path);
        Info info;
        if (!GetFileInformationByHandle(h, out info) || (info.Attributes & 0x400) != 0 || (info.Attributes & 0x10) == 0) {
            h.Dispose(); throw new IOException("Directory/reparse check failed: " + path);
        }
        return h;
    }
    public static void CreatePrivateDirectory(string path) {
        string sid = System.Security.Principal.WindowsIdentity.GetCurrent().User.Value;
        IntPtr sd; uint size;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor("D:P(A;OICI;FA;;;" + sid + ")(A;OICI;FA;;;SY)", 1, out sd, out size))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {
            SecurityAttributes sa = new SecurityAttributes();
            sa.Length = Marshal.SizeOf(sa); sa.Descriptor = sd;
            if (!CreateDirectory(path, ref sa)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), path);
        } finally { LocalFree(sd); }
    }
}
'@
}

function Get-BytesHash([byte[]]$bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-BoundedBytes([string]$path) {
    $stream = New-Object System.IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt 8MB) { throw ('File exceeds 8 MiB snapshot limit: ' + $path) }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) { throw 'Unexpected EOF while freezing source' }
            $offset += $read
        }
        return ,$bytes
    } finally { $stream.Dispose() }
}

function Get-SafeTree([string]$root) {
    if (Check-ReparsePointChain $root) { throw ('Reparse point forbidden: ' + $root) }
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw ('Reparse point forbidden: ' + $item.FullName) }
        $item
        if ($item.PSIsContainer) { Get-SafeTree $item.FullName }
    }
}

function Hold-DirectoryChain([string]$path, $handles) {
    Ensure-FilesystemHelper
    $drive = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($path)))
    if ($drive.DriveType -ne [IO.DriveType]::Fixed -or $drive.DriveFormat -cne 'NTFS') { throw 'Supported filesystem is local fixed NTFS only (no UNC/network/removable filesystems)' }
    $chain = New-Object System.Collections.Generic.List[string]
    $current = [System.IO.Path]::GetFullPath($path)
    while ($current) {
        $chain.Add($current)
        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
    for ($i = $chain.Count - 1; $i -ge 0; $i--) { $handles.Add([JanusFs]::HoldDirectory($chain[$i])) }
}

function Remove-OwnedTemp([string]$path, [string]$parent, [string]$name) {
    # Never follow links, never delete a caller target, never wildcard cleanup.
    if ([System.IO.Path]::GetFullPath($path) -cne [System.IO.Path]::Combine($parent, $name) -or $name -notmatch '^janus_(stage|test)_[0-9a-f]{32}$') {
        throw 'Cleanup ownership boundary rejected'
    }
    if (-not [System.IO.Directory]::Exists($path)) { return }
    $handles = New-Object 'System.Collections.Generic.List[System.IDisposable]'
    try {
        Hold-DirectoryChain $path $handles
        Assert-TrustedStageParent $parent
        $items = @(Get-SafeTree $path)
        foreach ($dir in @($items | Where-Object { $_.PSIsContainer })) { $handles.Add([JanusFs]::HoldDirectory($dir.FullName)) }
        foreach ($file in @($items | Where-Object { -not $_.PSIsContainer })) { [System.IO.File]::Delete($file.FullName) }
    } finally { for ($i = $handles.Count - 1; $i -ge 0; $i--) { $handles[$i].Dispose() } }
    # Private ACL excludes other identities; same-identity/admin interference is outside the bound.
    foreach ($dir in @($items | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending)) {
        if (Check-ReparsePointChain $dir.FullName) { throw 'Cleanup refused changed directory' }
        [System.IO.Directory]::Delete($dir.FullName, $false)
    }
    if (Check-ReparsePointChain $path) { throw 'Cleanup refused changed root' }
    [System.IO.Directory]::Delete($path, $false)
}

function Assert-TrustedStageParent([string]$path) {
    # A private child DACL alone does not defeat DELETE_CHILD on its parent.
    # Fail closed even when a deny ACE might override an unsafe allow ACE.
    $trusted = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
    $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
    if ($trusted -cnotcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) {
        throw ('Untrusted stage parent owner: ' + $path)
    }
    $dangerous = [long]0x100C0040 # GENERIC_ALL, WRITE_DAC, WRITE_OWNER, FILE_DELETE_CHILD
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
        if ($trusted -cnotcontains $rule.IdentityReference.Value -and ([long]$rule.FileSystemRights -band $dangerous)) {
            throw ('Unsafe stage parent replacement permissions: ' + $path + ' principal=' + $rule.IdentityReference.Value)
        }
    }
}

function Invoke-StageFault([string]$point, [string]$tempPath, [string]$targetPath) {
    # Internal test seam only: no parameter, environment variable, or CLI fault control.
    if ($null -ne $script:JanusStageFault) { & $script:JanusStageFault $point $tempPath $targetPath }
}

function Write-FrozenSnapshot($snapshot, [string]$tempPath, [string]$targetPath) {
    foreach ($entry in $snapshot) {
        if ($Global:JanusWhitelist14 -cnotcontains $entry.path -or -not (Validate-ManifestPathSafe $entry.path $tempPath).IsValid) { throw 'Snapshot destination rejected' }
        $dst = [System.IO.Path]::GetFullPath((Join-Path $tempPath $entry.path))
        if (-not $dst.StartsWith((Ensure-TrailingSlash $tempPath), [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Snapshot destination escaped temp' }
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dst))
        if (Check-ReparsePointChain $dst) { throw 'Reparse point at copy destination' }
        $bytes = [Convert]::FromBase64String($entry.ContentBase64)
        if ((Get-BytesHash $bytes) -cne $entry.sha256) { throw 'Frozen bytes digest mismatch' }
        $stream = New-Object System.IO.FileStream($dst, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        Invoke-StageFault 'MidCopy' $tempPath $targetPath
    }
}

function Stage-ReleasePackage([string]$manifestPath, [string]$sourceRoot, [string]$targetStagingPath) {
    $sourceRoot = [System.IO.Path]::GetFullPath($sourceRoot).TrimEnd('\', '/')
    $targetStagingPath = [System.IO.Path]::GetFullPath($targetStagingPath).TrimEnd('\', '/')
    if (Test-Path -LiteralPath $targetStagingPath) { throw ('Staging target must not exist prior to staging: ' + $targetStagingPath) }
    if ((Ensure-TrailingSlash $targetStagingPath).StartsWith((Ensure-TrailingSlash $sourceRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Staging target must be outside source root'
    }
    $parent = [System.IO.Path]::GetDirectoryName($targetStagingPath)
    $leafCheck = Validate-ManifestPathSafe ([System.IO.Path]::GetFileName($targetStagingPath)) $targetStagingPath
    if (-not $leafCheck.IsValid) { throw $leafCheck.Message }
    if ([System.IO.Path]::GetFullPath($manifestPath) -cne [System.IO.Path]::Combine($sourceRoot, 'release-manifest.json')) { throw 'Manifest must be the exact source release-manifest.json' }
    $handles = New-Object 'System.Collections.Generic.List[System.IDisposable]'
    $tempPath = $null
    $owned = $false
    try {
        Hold-DirectoryChain $parent $handles
        Assert-TrustedStageParent $parent
        Hold-DirectoryChain $sourceRoot $handles
        $sourceTree = @(Get-SafeTree $sourceRoot)
        foreach ($dir in @($sourceTree | Where-Object { $_.PSIsContainer })) { $handles.Add([JanusFs]::HoldDirectory($dir.FullName)) }
        foreach ($file in @($sourceTree | Where-Object { -not $_.PSIsContainer })) {
            $handles.Add((New-Object System.IO.FileStream($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)))
        }
        $sourceVal = Validate-JanusPackage $manifestPath $sourceRoot 'Source'
        if (-not $sourceVal.IsValid) { throw ('Source validation failed prior to staging: ' + $sourceVal.DiagnosticCode + ' - ' + $sourceVal.Message) }
        $snapshot = $sourceVal.Snapshot
        Invoke-StageFault 'Snapshot' '' $targetStagingPath
        $tempName = 'janus_stage_' + [Guid]::NewGuid().ToString('N')
        $tempPath = [System.IO.Path]::Combine($parent, $tempName)
        [JanusFs]::CreatePrivateDirectory($tempPath)
        $owned = $true
        Write-Host ('STAGE_TEMP: ' + $tempPath)
        Write-Host 'Bound: local fixed NTFS only; held non-reparse ancestors, trusted parent replacement permissions and inherited private ACL; 8 MiB/file, 32 MiB/package. Same-identity/admin/kernel interference is excluded. Hard kill can leave this exact temp path; inspect it before manual no-follow removal.'
        Write-FrozenSnapshot $snapshot $tempPath $targetStagingPath
        Invoke-StageFault 'PostCopy' $tempPath $targetStagingPath
        $val = Validate-JanusPackage (Join-Path $tempPath 'release-manifest.json') $tempPath 'Release'
        if (-not $val.IsValid -or $val.package_digest -cne $sourceVal.package_digest) {
            throw ('Staging verification failed in Release mode: ' + $val.DiagnosticCode + ' - ' + $val.Message)
        }
        Invoke-StageFault 'BeforeRename' $tempPath $targetStagingPath
        # Same-parent rename, Directory.Move never replaces an existing target.
        [System.IO.Directory]::Move($tempPath, $targetStagingPath)
        $owned = $false
        return [pscustomobject]@{ payload_digest = $val.payload_digest; package_digest = $val.package_digest }
    } finally {
        if ($owned) {
            try { Remove-OwnedTemp $tempPath $parent $tempName }
            catch { Write-Warning ('OWNED_TEMP_RETAINED: ' + $tempPath + ' - ' + $_.Exception.Message) }
        }
        for ($i = $handles.Count - 1; $i -ge 0; $i--) { $handles[$i].Dispose() }
    }
}

function Write-Utf8NoBom([string]$path, [string]$content) {
    [IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding $false))
}

function Run-SelfTests([string]$scriptPath, [bool]$includeLivePackage = $true) {
    $stats = [ordered]@{ pass = 0; fail = 0; skip = 0 }
    $requiredGroups = @('metadata', 'encoding-policy', 'manifest-types', 'snapshot', 'protocol', 'manifest-bom-case', 'stage-faults', 'stage-success', 'ads', 'junction', 'directory-lock', 'parent-acl', 'size', 'live')
    # Planned assertion counts are independent of execution; intentional suite edits update this ledger.
    $requiredCounts = @{
        'metadata' = 19; 'encoding-policy' = 15; 'manifest-types' = 15; 'snapshot' = 3
        'protocol' = 13; 'manifest-bom-case' = 2; 'stage-faults' = 9; 'stage-success' = 2
        'ads' = 2; 'junction' = 3; 'directory-lock' = 1; 'parent-acl' = 3; 'size' = 1; 'live' = 1
    }
    $completedGroups = @{}
    $assertionIds = @{}
    function Assert-Test([bool]$condition, [string]$description, [string]$detail = '') {
        if ($assertionIds.ContainsKey($description)) { $stats.fail++; Write-Host ('[FAIL] Duplicate assertion: ' + $description); return }
        $assertionIds[$description] = $true
        if ($condition) { $stats.pass++; Write-Host ('[PASS] ' + $description) }
        else { $stats.fail++; Write-Host ('[FAIL] ' + $description + ' ' + $detail) }
    }
    function Skip-Test([string]$description) { $stats.skip++; Write-Host ('[SKIP] ' + $description) }
    function Assert-Throws([scriptblock]$action, [string]$description, [string]$expected = '', [type]$exceptionType = $null, [int[]]$errorCodes = @()) {
        if ([string]::IsNullOrEmpty($expected) -and $null -eq $exceptionType) { throw 'Expected diagnostic or exception type is required' }
        $matched = $false
        $message = ''
        try { & $action | Out-Null } catch {
            $message = $_.Exception.ToString()
            for ($errorItem = $_.Exception; $null -ne $errorItem; $errorItem = $errorItem.InnerException) {
                $typeMatches = $null -eq $exceptionType -or $exceptionType.IsInstanceOfType($errorItem)
                $codeMatches = $errorCodes.Count -eq 0 -or $errorCodes -contains ($errorItem.HResult -band 0xffff)
                $textMatches = [string]::IsNullOrEmpty($expected) -or $errorItem.Message -match $expected
                if ($typeMatches -and $codeMatches -and $textMatches) { $matched = $true; break }
            }
        }
        Assert-Test $matched $description $message
    }
    # Fixture-only manifest construction never touches the source manifest or docs.
    function Reset-FixtureManifest([string]$root) {
        $entries = @($Global:JanusWhitelist14 | ForEach-Object {
            $hash = if ($_ -ceq 'release-manifest.json') { 'self-manifest-schema-only' } else { Get-BytesHash (Read-BoundedBytes (Join-Path $root $_)) }
            [pscustomobject]@{ path = $_; category = 'fixture'; ship = $true; sha256 = $hash }
        })
        $manifest = [ordered]@{ schema_version = '2.0.0'; skill_name = 'janus'; total_files = 14; ship_true_count = 14; ship_false_count = 0; payload_digest = (Compute-PayloadDigest $entries); files = $entries }
        Write-Utf8NoBom (Join-Path $root 'release-manifest.json') ($manifest | ConvertTo-Json -Depth 6)
    }
    Ensure-FilesystemHelper
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $name = 'janus_test_' + [Guid]::NewGuid().ToString('N')
    $tempDir = Join-Path $parent $name
    $parentHandles = New-Object 'System.Collections.Generic.List[System.IDisposable]'
    $owned = $false
    try {
        Hold-DirectoryChain $parent $parentHandles
        Assert-TrustedStageParent $parent
        [JanusFs]::CreatePrivateDirectory($tempDir)
        $owned = $true
        Write-Host ('SELFTEST_TEMP: ' + $tempDir)
        $sourceRoot = Split-Path (Split-Path $scriptPath -Parent) -Parent
        [void]@(Get-SafeTree $sourceRoot)
        $fixture = Join-Path $tempDir 'fixture'
        [void][IO.Directory]::CreateDirectory($fixture)
        foreach ($relative in $Global:JanusWhitelist14) {
            if ($relative -ceq 'release-manifest.json') { continue }
            $dst = Join-Path $fixture $relative
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))
            [IO.File]::WriteAllBytes($dst, (Read-BoundedBytes (Join-Path $sourceRoot $relative)))
        }
        Reset-FixtureManifest $fixture
        $manifestPath = Join-Path $fixture 'release-manifest.json'
        $baseline = Validate-JanusPackage $manifestPath $fixture 'Source'
        Assert-Test $baseline.IsValid 'Fixture: unified gate with fresh fixture hashes' $baseline.Message
        if (-not $baseline.IsValid) { throw ('Fixture cannot support stage tests: ' + $baseline.DiagnosticCode + ' ' + $baseline.Message) }

        $groups = @(
            @{ Id = 'metadata'; Action = {
        foreach ($raw in @('value: nested', '[a,b]', '*alias', '|', '%TAG', '"bad\q"', '"unterminated', 'true', 'null', '123', '.nan', '2026-09-11')) {
            Assert-Test (-not (Parse-RestrictedYamlScalar $raw).IsValid) ('YAML rejects ' + $raw)
        }
        $scalar = Parse-RestrictedYamlScalar '"a\n\u0042\\c"'
        Assert-Test ($scalar.IsValid -and $scalar.Value -ceq ("a" + [char]10 + 'B\c')) 'YAML deterministic escaped decoding'
        $fmPath = Join-Path $tempDir 'frontmatter.md'
        foreach ($newline in @("`n", "`r`n")) {
            Write-Utf8NoBom $fmPath ((@('---', 'name: janus', 'description: "123"', '---') -join $newline))
            Assert-Test (Validate-SkillFrontmatter $fmPath).IsValid ('Frontmatter accepts quoted string and newline length ' + $newline.Length)
        }
        Write-Utf8NoBom $fmPath ('---' + [char]10 + 'name: janus' + [char]10 + 'description: "\u0020\t"' + [char]10 + '---')
        Assert-Test ((Validate-SkillFrontmatter $fmPath).DiagnosticCode -eq 'DIAG_FM_DESC_EMPTY') 'YAML decoded whitespace description rejected'
        Write-Utf8NoBom $fmPath ('---' + [char]10 + 'name: janus' + [char]10 + 'description: valid' + [char]10 + 'bypass_gate: extra' + [char]10 + '---')
        Assert-Test ((Validate-SkillFrontmatter $fmPath).DiagnosticCode -eq 'DIAG_FM_UNKNOWN_KEY') 'Frontmatter rejects unknown key'
        $yamlPath = Join-Path $tempDir 'openai.yaml'
        Write-Utf8NoBom $yamlPath ('interface:' + [char]10 + '  display_name: Janus' + [char]10 + '  short_description: Fullstack' + [char]10 + '  default_prompt: Plan' + [char]10 + '  inject_action: rm')
        Assert-Test ((Validate-OpenAiYaml $yamlPath).DiagnosticCode -eq 'DIAG_YAML_UNKNOWN_CHILD_KEY') 'YAML rejects unknown interface key'
        $bomPath = Join-Path $tempDir 'bom.md'
        [IO.File]::WriteAllBytes($bomPath, ([byte[]](0xEF,0xBB,0xBF) + [Text.Encoding]::UTF8.GetBytes(('---' + [char]10 + 'name: janus' + [char]10 + 'description: valid' + [char]10 + '---'))))
        Assert-Test ((Validate-SkillFrontmatter $bomPath).DiagnosticCode -eq 'DIAG_UTF8_BOM_FORBIDDEN') 'Frontmatter rejects UTF-8 BOM'
            } },
            @{ Id = 'encoding-policy'; Action = {
                $yamlPath = Join-Path $tempDir 'policy.yaml'
                $interface = "interface:`n  display_name: Janus`n  short_description: Fullstack`n  default_prompt: Plan`n"
                foreach ($case in @(
                    @("policy:`n  allow_implicit_invocation: false`n", 'OK'),
                    @("policy:`n  allow_implicit_invocation: true`n", 'DIAG_YAML_POLICY_VALUE'),
                    @(('policy:' + [char]10 + '  allow_implicit_invocation: "false"'), 'DIAG_YAML_POLICY_TYPE'),
                    @('', 'DIAG_YAML_POLICY_MISSING'),
                    @("policy:`n  allow_implicit_invocation: false`n  allow_implicit_invocation: false", 'DIAG_YAML_DUPLICATE_CHILD_KEY'),
                    @("policy:`n  unknown: false", 'DIAG_YAML_UNKNOWN_CHILD_KEY'),
                    @("policy:`n    allow_implicit_invocation: false", 'DIAG_YAML_SYNTAX_ERROR'),
                    @("policy:`n  allow_implicit_invocation: false`npolicy:", 'DIAG_YAML_DUPLICATE_TOP_KEY'))) {
                    Write-Utf8NoBom $yamlPath ($interface + $case[0])
                    Assert-Test ((Validate-OpenAiYaml $yamlPath).DiagnosticCode -ceq $case[1]) ('Policy: ' + $case[1])
                }
                $bad = Join-Path $tempDir 'invalid-utf8'
                [IO.File]::WriteAllBytes($bad, [byte[]](0xC3,0x28))
                Assert-Throws { Read-Utf8NoBomText $bad } 'Strict UTF-8 rejects invalid bytes' '' ([Text.DecoderFallbackException])
                Assert-Test ((Validate-SkillFrontmatter $bad).DiagnosticCode -ceq 'DIAG_UTF8_INVALID') 'Frontmatter strict UTF-8'
                Assert-Test ((Validate-OpenAiYaml $bad).DiagnosticCode -ceq 'DIAG_UTF8_INVALID') 'Profile strict UTF-8'
                Assert-Test ((Validate-ReleaseManifestJson $bad $fixture 'Source').DiagnosticCode -ceq 'DIAG_UTF8_INVALID') 'Manifest strict UTF-8'
                $readme = Join-Path $fixture 'README.md'
                $original = [IO.File]::ReadAllBytes($readme)
                try {
                    [IO.File]::WriteAllBytes($readme, ([byte[]](0xEF,0xBB,0xBF) + $original))
                    Assert-Test ((Validate-JanusPackage $manifestPath $fixture 'Source').DiagnosticCode -ceq 'DIAG_UTF8_BOM_FORBIDDEN') 'Package rejects Markdown BOM'
                    [IO.File]::WriteAllBytes($readme, [byte[]](0xC3,0x28))
                    Assert-Test ((Validate-JanusPackage $manifestPath $fixture 'Source').DiagnosticCode -ceq 'DIAG_ENCODING_READ_FAILED') 'Package rejects malformed Markdown bytes'
                } finally { [IO.File]::WriteAllBytes($readme, $original) }
                $ps1 = Join-Path $fixture 'scripts/validate-fullstack-skills.ps1'
                $original = [IO.File]::ReadAllBytes($ps1)
                try {
                    [IO.File]::WriteAllBytes($ps1, $original[3..($original.Length - 1)])
                    Assert-Test ((Validate-JanusPackage $manifestPath $fixture 'Source').DiagnosticCode -ceq 'DIAG_PS1_BOM_REQUIRED') 'Package requires script BOM'
                } finally { [IO.File]::WriteAllBytes($ps1, $original) }
            } },
            @{ Id = 'manifest-types'; Action = {
        foreach ($path in @('../escape', 'file:ads', 'references/CON.txt', 'references/a?.md', 'references/a.', 'references//a')) {
            Assert-Test (-not (Validate-ManifestPathSafe $path $manifestPath).IsValid) ('Path rejects ' + $path)
        }
        Assert-Test (-not (Check-JsonNoDuplicateKeys '{"skill_name":"janus","\u0073kill_name":"x"}' $manifestPath).IsValid) 'JSON escaped duplicate key rejected'
        $manifestText = [IO.File]::ReadAllText($manifestPath)
        foreach ($field in @('total_files', 'ship_true_count', 'ship_false_count', 'files', 'category', 'path', 'sha256', 'ship')) {
            $m = $manifestText | ConvertFrom-Json
            if ($field -in @('category', 'path', 'sha256', 'ship')) { $m.files[0].$field = $null }
            elseif ($field -eq 'files') { $m.files = $m.files[0] }
            else { $m.$field = [string]$m.$field }
            Write-Utf8NoBom $manifestPath ($m | ConvertTo-Json -Depth 6)
            Assert-Test (-not (Validate-ReleaseManifestJson $manifestPath $fixture 'Source').IsValid) ('Manifest strict type: ' + $field)
        }
        Write-Utf8NoBom $manifestPath $manifestText
            } },
            @{ Id = 'snapshot'; Action = {
        $frozen = Validate-ReleaseManifestJson $manifestPath $fixture 'Source'
        Write-Utf8NoBom $manifestPath '{"files":[{"path":"../escape"}]}'
        $frozenCopy = Join-Path $tempDir 'frozen_copy'
        [void][IO.Directory]::CreateDirectory($frozenCopy)
        Write-FrozenSnapshot $frozen.Snapshot $frozenCopy ''
        $copied = Validate-JanusPackage (Join-Path $frozenCopy 'release-manifest.json') $frozenCopy 'Release'
        Assert-Test ($copied.IsValid -and $copied.package_digest -ceq $frozen.package_digest) 'Snapshot: manifest mutation cannot alter frozen copy'
        Assert-Throws { $frozen.Snapshot[0].path = '../escape' } 'Snapshot entry is immutable' '' ([System.Management.Automation.SetValueException]) @(5377)
        Reset-FixtureManifest $fixture
        $before = Validate-ReleaseManifestJson $manifestPath $fixture 'Source'
        [IO.File]::AppendAllText($manifestPath, [string][char]10)
        $after = Validate-ReleaseManifestJson $manifestPath $fixture 'Source'
        Assert-Test ($before.payload_digest -ceq $after.payload_digest -and $before.package_digest -cne $after.package_digest) 'Digests: manifest-only bytes change package (14), not payload (13)'
        Reset-FixtureManifest $fixture
            } },
            @{ Id = 'protocol'; Action = {
        $controlPath = Join-Path $fixture 'references/control-plane.md'
        $control = [IO.File]::ReadAllText($controlPath)
        foreach ($pair in @(
            @('  cb_priority: LIFETIME_FIRST', '  cb_priority: STRATEGY_FIRST'),
            @('  lifetime_reset_on_resume: false', '  lifetime_reset_on_resume: "false"'),
            @('  partial_delivery_requires_acceptance: true', '  partial_delivery_requires_acceptance: false'),
            @('  gate_requires_valid_parent: true', ('  gate_requires_valid_parent: true' + [char]10 + '  gate_requires_valid_parent: true')),
            @('  source_write_requires_behavior_frozen: true', '  source_write_requires_behavior_frozen: false'),
            @('  unknown_history_policy: PRESERVE_AND_RECONCILE', '  unknown_history_policy: RESET'),
            @('  final_sweep_reuse: STABLE_AND_COMPLETE', '  final_sweep_reuse: ALWAYS'))) {
            Write-Utf8NoBom $controlPath ($control.Replace($pair[0], $pair[1]))
            Assert-Throws { Test-ProtocolModels $fixture } ('Model rejects mutation: ' + $pair[0]) 'protocol rule|protocol_rules|assignment'
        }
        Write-Utf8NoBom $controlPath $control
        $r1Path = Join-Path $fixture 'references/mode-standard.md'
        $r1Text = [IO.File]::ReadAllText($r1Path)
        Write-Utf8NoBom $r1Path ($r1Text.Replace('behavior_contract_status: "FROZEN"', 'behavior_contract_status: "DRAFT"'))
        Assert-Throws { Test-ProtocolModels $fixture } 'Model rejects unfrozen R1 behavior' 'behavior freeze'
        Write-Utf8NoBom $r1Path ($r1Text.Replace('interface_applicability: "IN_SCOPE"', 'interface_applicability: "NOT_APPLICABLE"').Replace('interface_contract_status: "FROZEN"', 'interface_contract_status: "NOT_APPLICABLE"'))
        $validNoInterface = $true
        try { Test-ProtocolModels $fixture } catch { $validNoInterface = $false }
        Assert-Test $validNoInterface 'Model accepts R1 no interface with frozen behavior'
        Write-Utf8NoBom $r1Path $r1Text
        $r2Path = Join-Path $fixture 'references/mode-strict.md'
        $r2Text = [IO.File]::ReadAllText($r2Path)
        Write-Utf8NoBom $r2Path ($r2Text.Replace('eligibility: BLOCKED_BY_UPSTREAM', 'eligibility: ELIGIBLE'))
        Assert-Throws { Test-ProtocolModels $fixture } 'Model rejects skipped Gate eligibility' 'eligibility mismatch'
        Write-Utf8NoBom $r2Path $r2Text
        Write-Utf8NoBom $r2Path ($r2Text.Replace('type: REQUESTED', 'type: IGNORED'))
        Assert-Throws { Test-ProtocolModels $fixture } 'Model rejects VALID Gate 1 without events' 'REQUESTED and APPROVED'
        Write-Utf8NoBom $r2Path $r2Text

        # Test janus-contract-v1 digest algorithm with frozen vectors from references/mode-standard.md
        function Compute-ContractDigest([string]$cText, [string]$aText) {
            $cNorm = ($cText -replace '\r\n', ([string][char]10) -replace '\r', ([string][char]10))
            $aNorm = ($aText -replace '\r\n', ([string][char]10) -replace '\r', ([string][char]10))
            $cBytes = [System.Text.Encoding]::UTF8.GetBytes($cNorm)
            $aBytes = [System.Text.Encoding]::UTF8.GetBytes($aNorm)
            $cLen = [System.Text.Encoding]::ASCII.GetBytes($cBytes.Length.ToString() + ':')
            $aLen = [System.Text.Encoding]::ASCII.GetBytes($aBytes.Length.ToString() + ':')
            $prefix = [System.Text.Encoding]::UTF8.GetBytes('janus-contract-v1' + [char]10)
            $stream = New-Object System.Collections.Generic.List[byte]
            $stream.AddRange($prefix)
            $stream.AddRange($cLen)
            $stream.AddRange($cBytes)
            $stream.AddRange($aLen)
            $stream.AddRange($aBytes)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $hash = [BitConverter]::ToString($sha.ComputeHash($stream.ToArray())).Replace('-', '').ToLowerInvariant()
            $sha.Dispose()
            return $hash
        }
        $cVec = '返回 201' + [char]13 + [char]10 + '## Event Log' + [char]13 + [char]10
        $aVec1 = '字段 id 非空' + [char]13 + [char]10 + [char]13 + [char]10
        $aVec2 = '字段 id 非空' + [char]13 + [char]10
        $hash1 = Compute-ContractDigest $cVec $aVec1
        $hash2 = Compute-ContractDigest $cVec $aVec2
        Assert-Test ($hash1 -ceq 'd7bb1264e97e09ebffafb559ed18ed6fd39f22368faed49d82236762ae4c1270') 'Contract digest: frozen vector 1'
        Assert-Test ($hash2 -ceq 'bd59d8071f9e05b9947a33bbbe04ac738b54072b3c9ecdce09fe64db64b5b66f') 'Contract digest: frozen vector 2 (trailing newline sensitivity)'
            } },
            @{ Id = 'manifest-bom-case'; Action = {
        $bomManifest = Join-Path $tempDir 'bom-manifest.json'
        [IO.File]::WriteAllBytes($bomManifest, ([byte[]](0xEF,0xBB,0xBF) + [Text.Encoding]::UTF8.GetBytes($manifestText)))
        Assert-Test ((Validate-ReleaseManifestJson $bomManifest $fixture 'Source').DiagnosticCode -eq 'DIAG_UTF8_BOM_FORBIDDEN') 'Manifest rejects UTF-8 BOM'
        $caseSrc = Join-Path $fixture 'README.md'
        $caseDst = Join-Path $fixture 'readme.md'
        [IO.File]::Move($caseSrc, $caseDst)
        $caseResult = Validate-JanusPackage $manifestPath $fixture 'Source'
        Assert-Test (-not $caseResult.IsValid -and $caseResult.DiagnosticCode -eq 'DIAG_MANIFEST_UNLISTED_FILE') 'Source rejects case-shifted filename' $caseResult.DiagnosticCode
        [IO.File]::Move($caseDst, $caseSrc)
        Reset-FixtureManifest $fixture
            } },
            @{ Id = 'stage-faults'; Action = {
        foreach ($fault in @('MidCopy', 'PostCopy', 'BeforeRename')) {
            $target = Join-Path $tempDir ('failure_' + $fault)
            $script:JanusStageFault = {
                param($point, $temp, $final)
                if ($point -ceq $fault) {
                    if ($point -ceq 'MidCopy') { throw 'Injected mid-copy failure' }
                    if ($point -ceq 'PostCopy') { [IO.File]::AppendAllText((Join-Path $temp 'README.md'), 'tamper') }
                    if ($point -ceq 'BeforeRename') {
                        [void][IO.Directory]::CreateDirectory($final)
                        [IO.File]::WriteAllText((Join-Path $final 'competitor.txt'), 'preserve', (New-Object System.Text.UTF8Encoding $false))
                    }
                }
            }.GetNewClosure()
            try {
                if ($fault -ceq 'BeforeRename') {
                    Assert-Throws { Stage-ReleasePackage $manifestPath $fixture $target } ('Stage failure: ' + $fault) '' ([IO.IOException]) @(183)
                } else {
                    $expected = if ($fault -ceq 'MidCopy') { 'Injected mid-copy failure' } else { 'Staging verification failed.*HASH_MISMATCH' }
                    Assert-Throws { Stage-ReleasePackage $manifestPath $fixture $target } ('Stage failure: ' + $fault) $expected
                }
            } finally { $script:JanusStageFault = $null }
            Assert-Test (@(Get-ChildItem -LiteralPath $tempDir -Directory -Filter 'janus_stage_*').Count -eq 0) ('Stage own-temp cleanup: ' + $fault)
            if ($fault -ceq 'BeforeRename') {
                Assert-Test ([IO.File]::ReadAllText((Join-Path $target 'competitor.txt')) -ceq 'preserve') 'Target race preserves competitor directory'
            } else { Assert-Test (-not (Test-Path -LiteralPath $target)) ('Failed stage never publishes: ' + $fault) }
        }
            } },
            @{ Id = 'stage-success'; Action = {
        $target = Join-Path $tempDir 'success'
        $digests = Stage-ReleasePackage $manifestPath $fixture $target
        $release = Validate-JanusPackage (Join-Path $target 'release-manifest.json') $target 'Release'
        Assert-Test ($release.IsValid -and $digests.package_digest -ceq $release.package_digest) 'Stage successful same-parent publish and full Release gate'
        Assert-Throws { Stage-ReleasePackage $manifestPath $fixture $target } 'Stage rejects existing target' 'must not exist'
            } },
            @{ Id = 'ads'; Action = {
        $adsFile = Join-Path $fixture 'README.md'
        # NTFS support was established above. A failed stream probe is a FAIL, never SKIP.
        try {
            Set-Content -LiteralPath $adsFile -Stream 'janus_test' -Value 'hidden'
            Assert-Test ((Check-DirectoryHasAds $fixture).DiagnosticCode -ceq 'DIAG_NTFS_ADS_DETECTED') 'ADS production detector rejects named stream'
            Assert-Throws { Stage-ReleasePackage $manifestPath $fixture (Join-Path $tempDir 'ads_stage') } 'Stage rejects source ADS' 'ADS'
        } finally { Remove-Item -LiteralPath $adsFile -Stream 'janus_test' -ErrorAction Stop }
            } },
            @{ Id = 'junction'; Action = {
        $outside = Join-Path $tempDir 'junction_target'
        $link = Join-Path $fixture 'junction_probe'
        [void][IO.Directory]::CreateDirectory($outside)
        Write-Utf8NoBom (Join-Path $outside 'sentinel') 'preserve'
        try {
            [void](New-Item -ItemType Junction -Path $link -Target $outside -ErrorAction Stop)
            Assert-Throws { Get-SafeTree $fixture } 'Directory junction rejected before descent' 'Reparse point'
            Assert-Throws { Stage-ReleasePackage $manifestPath $fixture (Join-Path $tempDir 'junction_stage') } 'Stage rejects junction tree' 'Reparse point'
        } finally {
            # Delete only the link object, never recursively traverse it.
            if ([IO.Directory]::Exists($link)) { [IO.Directory]::Delete($link, $false) }
        }
        Assert-Test ([IO.File]::ReadAllText((Join-Path $outside 'sentinel')) -ceq 'preserve') 'Junction target untouched'
            } },
            @{ Id = 'directory-lock'; Action = {
        $lockDir = Join-Path $tempDir 'held'
        [void][IO.Directory]::CreateDirectory($lockDir)
        $hold = [JanusFs]::HoldDirectory($lockDir)
        try { Assert-Throws { [IO.Directory]::Move($lockDir, (Join-Path $tempDir 'swapped')) } 'Directory handle blocks ancestry rename' '' ([IO.IOException]) @(32) }
        finally { $hold.Dispose() }
            } },
            @{ Id = 'parent-acl'; Action = {
        $aclProbe = Join-Path $tempDir 'unsafe_parent'
        [void][IO.Directory]::CreateDirectory($aclProbe)
        $acl = Get-Acl -LiteralPath $aclProbe
        $everyone = New-Object Security.Principal.SecurityIdentifier('S-1-1-0')
        $unsafeRule = New-Object Security.AccessControl.FileSystemAccessRule($everyone, [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles, [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($unsafeRule)
        Set-Acl -LiteralPath $aclProbe -AclObject $acl
        Assert-Throws { Assert-TrustedStageParent $aclProbe } 'Parent DELETE_CHILD for another principal rejected' 'replacement permissions'
        Assert-Throws { Stage-ReleasePackage $manifestPath $fixture (Join-Path $aclProbe 'candidate') } 'Stage refuses unsafe parent before creating temp' 'replacement permissions'
        Assert-Test (@(Get-ChildItem -LiteralPath $aclProbe -Force).Count -eq 0) 'Unsafe parent rejection leaves no artifacts'
            } },
            @{ Id = 'size'; Action = {
        $large = Join-Path $tempDir 'oversize'
        $stream = [IO.File]::Create($large)
        try { $stream.SetLength(8MB + 1) } finally { $stream.Dispose() }
        Assert-Throws { Read-BoundedBytes $large } 'Snapshot per-file size bound' '8 MiB'
            } },
            @{ Id = 'live'; Action = {
        if ($includeLivePackage) {
            $live = Validate-JanusPackage (Join-Path $sourceRoot 'release-manifest.json') $sourceRoot 'Source'
            Assert-Test $live.IsValid 'Live source package (requires refreshed manifest)' ($live.DiagnosticCode + ' ' + $live.Message)
        } else { Skip-Test 'Live source package explicitly excluded by internal focused-helper invocation' }
            } }
        )
        $seenGroups = @{}
        foreach ($group in $groups) {
            $id = $group.Id
            if ($requiredGroups -cnotcontains $id -or $seenGroups.ContainsKey($id)) {
                Assert-Test $false ('Group identity: ' + $id) 'Unexpected or duplicate group'
                continue
            }
            $seenGroups[$id] = $true
            $completedGroups[$id] = $false
            try {
                # Each group starts from frozen source bytes: failed restoration cannot poison the next.
                $fixture = Join-Path $tempDir ('fixture_' + $id)
                [void][IO.Directory]::CreateDirectory($fixture)
                Write-FrozenSnapshot $baseline.Snapshot $fixture ''
                $manifestPath = Join-Path $fixture 'release-manifest.json'
                $manifestText = [IO.File]::ReadAllText($manifestPath)
                $beforeCount = $stats.pass + $stats.fail + $stats.skip
                . $group.Action
                $actualCount = $stats.pass + $stats.fail + $stats.skip - $beforeCount
                if ($actualCount -ne $requiredCounts[$id]) { throw ('Assertion count mismatch: expected ' + $requiredCounts[$id] + ', actual ' + $actualCount) }
                $completedGroups[$id] = $true
            } catch {
                Assert-Test $false ('Group exception: ' + $id) $_.Exception.Message
            } finally { $script:JanusStageFault = $null }
        }
    } catch {
        Assert-Test $false 'Self-test unexpected exception (not capability skip)' $_.Exception.Message
    } finally {
        $script:JanusStageFault = $null
        if ($owned) {
            try { Remove-OwnedTemp $tempDir $parent $name }
            catch { Assert-Test $false 'Self-test cleanup' $_.Exception.Message; Write-Warning ('OWNED_TEMP_RETAINED: ' + $tempDir) }
        }
        for ($i = $parentHandles.Count - 1; $i -ge 0; $i--) { $parentHandles[$i].Dispose() }
    }
    foreach ($id in $requiredGroups) {
        Assert-Test ($completedGroups.ContainsKey($id) -and $completedGroups[$id]) ('Required group completed: ' + $id)
    }
    Write-Host ('SELF-TEST: PASS=' + $stats.pass + ' FAIL=' + $stats.fail + ' SKIP=' + $stats.skip)
    if ($stats.fail -gt 0) { return 3 }
    return 0
}

$scriptFile = $MyInvocation.MyCommand.Definition
$scriptDir = Split-Path -Path $scriptFile -Parent
$skillDir = Split-Path -Path $scriptDir -Parent

if ($SelfTest) {
    $code = Run-SelfTests $scriptFile
    exit $code
}

if ($RefreshManifest) {
    Write-Host 'Refreshing release-manifest.json...' -ForegroundColor Cyan
    $manifestPath = Join-Path $skillDir 'release-manifest.json'
    $manifest = [IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($entry in $manifest.files) {
        if ($entry.path -cne 'release-manifest.json') {
            $fullPath = Join-Path $skillDir $entry.path
            $bytes = Read-BoundedBytes $fullPath
            $entry.sha256 = (Get-BytesHash $bytes).ToLowerInvariant()
        }
    }
    $manifest.payload_digest = Compute-PayloadDigest $manifest.files
    $jsonOut = ($manifest | ConvertTo-Json -Depth 6) + [System.Environment]::NewLine
    Write-Utf8NoBom $manifestPath $jsonOut
    Write-Host ('Updated payload_digest: ' + $manifest.payload_digest) -ForegroundColor Green
    $verifyRes = Validate-JanusPackage $manifestPath $skillDir 'Source'
    if ($verifyRes.IsValid) {
        Write-Host ('Manifest refreshed and verified. package_digest: ' + $verifyRes.package_digest) -ForegroundColor Green
        exit 0
    } else {
        Write-Host ('Verification failed after refresh: ' + $verifyRes.Message) -ForegroundColor Red
        exit 1
    }
}

if (-not [string]::IsNullOrWhiteSpace($StageRelease)) {
    Write-Host ('Staging release package to: ' + $StageRelease) -ForegroundColor Cyan
    $manifestPath = Join-Path $skillDir 'release-manifest.json'
    $digest = Stage-ReleasePackage $manifestPath $skillDir $StageRelease
    Write-Host ('payload_digest (13 files): ' + $digest.payload_digest) -ForegroundColor Green
    Write-Host ('package_digest (14 files): ' + $digest.package_digest) -ForegroundColor Green
    exit 0
}

Write-Host '=================================================================' -ForegroundColor Cyan
Write-Host ('Validating Janus Skill (' + $Mode + ' Mode)...') -ForegroundColor Cyan
Write-Host ('Target Root: ' + $skillDir) -ForegroundColor Cyan
Write-Host '=================================================================' -ForegroundColor Cyan

$manifestFile = Join-Path $skillDir 'release-manifest.json'
$packageRes = Validate-JanusPackage $manifestFile $skillDir $Mode

Write-Host ''
if ($packageRes.IsValid) {
    Write-Host ('payload_digest (13 files): ' + $packageRes.payload_digest)
    Write-Host ('package_digest (14 files): ' + $packageRes.package_digest)
    Write-Host ('  [PASS] Unified package gate: frontmatter, profile, protocol model, references, manifest, hashes and filesystem safety') -ForegroundColor Green
    Write-Host '=================================================================' -ForegroundColor Green
    Write-Host ('OK: Janus package PASSED in ' + $Mode + ' mode.') -ForegroundColor Green
    Write-Host '=================================================================' -ForegroundColor Green
    exit 0
} else {
    Write-Host ('  [FAIL] ' + $packageRes.DiagnosticCode + ' at ' + $packageRes.Path + ':' + $packageRes.Line) -ForegroundColor Red
    Write-Host ('         ' + $packageRes.Message) -ForegroundColor Red
    Write-Host '=================================================================' -ForegroundColor Red
    Write-Host 'VALIDATION FAILED: unified package gate rejected the candidate.' -ForegroundColor Red
    Write-Host '=================================================================' -ForegroundColor Red
    exit 1
}
