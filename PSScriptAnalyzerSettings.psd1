@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The install/verification scripts deliberately write progress to the
        # Azure run command transcript.
        'PSAvoidUsingWriteHost'

        # Azure VM run commands pass every value as a command-line string, so a
        # SecureString or PSCredential cannot arrive as a parameter. The
        # scripts build the credential in memory and never log or persist the
        # plaintext value.
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
}
