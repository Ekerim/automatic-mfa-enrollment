#
# automatic-mfa-enrollment.csh
#
# Automatic MFA enrollment enforcement for SSH-based access on Linux systems.
#
# This script enforces Google Authenticator MFA enrollment by:
#  - triggering enrollment during interactive SSH logins when required
#  - blocking non-interactive SSH sessions (scp/sftp/ssh command) for unenrolled users
#  - allowing exempt users, root, and su/sudo sessions by policy
#
# Designed to work reliably with OpenSSH and ThinLinc environments.
#
# Author: Fredrik Larsson
# Email: fredrik.larsson@fsdynamics.se
# Company: FS Dynamics Sweden AB
#
# License: GNU General Public License v3.0 (GPL-3.0)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#

#
# START of configuration section
#

# Group-based policy (forced enrollment is skipped for members)
set NO_MFA_GROUP = "no-mfa"
set OPTIONAL_MFA_GROUP = "optional-mfa"

# Path to the per-user Google Authenticator configuration file.
# Update this value if the file is stored elsewhere on your system.
# If the file is placed in a non-standard place, /etc/pam.d/sshd needs to be updated as well with the '... secret="<path>" ...' argument
#   to the PAM module for Google Authenticator.
set GOOGLE_AUTH_FILE = "$HOME/.google_authenticator"

# Timeout value for enrollment
set TIMEOUT = "240"

# Timeout wrapper command; set to empty string to disable the timeout process.
set TIMEOUT_CMD = "timeout --foreground --signal=SIGINT $TIMEOUT"

# Arguments passed to google-authenticator during enrollment. (See the man page for google-authenticator for help)
# '-f' is required so that writing of the ~/.google-authenticator file is forced
# '-D' is required to support Thinlinc logins (See https://www.cendio.com/resources/docs/tag/authentication_otp.html)
# If you have changed GOOGLE_AUTH_FILE from the default value, you need to add '-s $GOOGLE_AUTH_FILE' here
set GA_ARGS = "-f -t -D -r 3 -R 30 -S 30 -w 9"

# Full command that runs google-authenticator with the configured arguments.
set GA_CMD = "google-authenticator $GA_ARGS"

#
# END of configuration section
#

# Resolve username
set U = "unknown"
if ( $?USER ) then
    set U = "$USER"
else if ( $?user ) then
    set U = "$user"
else
    set U = `id -un`
endif

# Detect interactivity
set is_interactive = $?prompt

# LOG: script entry point
logger -t mfa-enroll "START enrollment script (csh): user=$U uid=$uid interactive=$is_interactive pid=$$"

# Do not enforce MFA for root
if ( "$uid" == "0" ) goto end

# Do not force enrollment in switched sessions (su/sudo)
if ( -f /proc/self/loginuid ) then
    set loginuid = `cat /proc/self/loginuid`
    if ( "$loginuid" != "4294967295" && "$loginuid" != "$uid" ) goto end
endif

# Group-based policy check
id -Gn | grep -qwE "${NO_MFA_GROUP}|${OPTIONAL_MFA_GROUP}"
if ( $status == 0 ) goto end

# Already enrolled check
if ( -f "$GOOGLE_AUTH_FILE" ) then
    logger -t mfa-enroll "User already enrolled, skipping: user=$U"
    goto end
endif

# Block Non-interactive SSH sessions for unenrolled users
if ( $is_interactive == 0 ) then
    if ( $?SSH_CONNECTION || $?SSH_CLIENT || $?SSH_TTY ) then
        logger -t mfa-enroll "DENY (not enrolled): Non-interactive SSH terminated: user=$U pid=$$"
        kill -HUP $$
        exit 1
    endif
    goto end
endif

# Ensure required commands exist
where google-authenticator >& /dev/null
if ( $status != 0 ) goto end

# --- ENROLLMENT PHASE ---

echo ""
echo "MFA enrollment is required for SSH access."
echo "Starting Multi-Factor setup now (timeout: ${TIMEOUT}s)..."
echo ""

# Enrollment status
set enrollment_verified = 0

logger -t mfa-enroll "Starting MFA enrollment: user=$U pid=$$"

# Execute GA
if ( "$TIMEOUT_CMD" != "" ) then
    $TIMEOUT_CMD $GA_CMD ; set rc = $status
else
    $GA_CMD ; set rc = $status
endif

# Double-check file creation (handles cases where SIGINT bypasses the trap)
if ( -f "$GOOGLE_AUTH_FILE" && ! -z "$GOOGLE_AUTH_FILE" ) then
    set enrollment_verified = 1
endif

if ( "$rc" == "0" && "$enrollment_verified" == "1" ) then
    logger -t mfa-enroll "Completed MFA enrollment (rc=$rc, verified=$enrollment_verified) for user=$U"
    echo "\nMFA enrollment completed."
    echo "You will now be logged out. Please log in again to verify MFA.\n"
else
    if ( "$rc" == "124" ) then
        logger -t mfa-enroll "TIMED OUT MFA enrollment (rc=$rc, verified=$enrollment_verified) for user=$U"
        echo "\nMFA enrollment timed out."
        echo "You will now be logged out. Please log in again and complete enrollment.\n"
    else if ( "$rc" == "130" ) then
        logger -t mfa-enroll "ABORTED MFA enrollment (Ctrl+C) (rc=$rc, verified=$enrollment_verified) for user=$U"
        echo "\nMFA enrollment was aborted (Ctrl+C)."
        echo "You will now be logged out.\n"
    else
        logger -t mfa-enroll "FAILED MFA enrollment (rc=$rc, verified=$enrollment_verified) for user=$U"
        echo "\nMFA enrollment failed."
        echo "You will now be logged out.\n"
    endif
endif

# Wait for key and terminate
echo "Press Enter to continue..."
set junk = $<
kill -HUP $$
exit

end:
