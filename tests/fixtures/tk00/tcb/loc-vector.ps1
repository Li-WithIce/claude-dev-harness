# Comment-only line.
$number = 1

<#
Block comment.
#>
$text = @"
alpha
beta
"@
if ($number -eq 1) {
    $text
}
