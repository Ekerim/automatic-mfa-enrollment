#
# automatic-mfa-enrollment.sh
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
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#

#
# START of configuration section
#

# Group-based policy (forced enrollment is skipped for members)
NO_MFA_GROUP="no-mfa"
OPTIONAL_MFA_GROUP="optional-mfa"

# Path to the per-user Google Authenticator configuration file.
# Update this value if the file is stored elsewhere on your system.
# If the file is placed in a non-standard place, /etc/pam.d/sshd needs to be updated as well with the '... secret="<path>" ...' argument
#   to the PAM module for Google Authenticator.
GOOGLE_AUTH_FILE="$HOME/.google_authenticator"

# Timeout value for enrollment
TIMEOUT="240"

# Timeout wrapper command; set to empty string to disable the timeout process.
TIMEOUT_CMD="timeout --foreground --signal=SIGINT $TIMEOUT"

# Arguments passed to google-authenticator during enrollment. (See the man page for google-authenticator for help)
# '-f' is required so that writing of the ~/.google-authenticator file is forced
# '-D' is required to support Thinlinc logins (See https://www.cendio.com/resources/docs/tag/authentication_otp.html)
# If you have changed GOOGLE_AUTH_FILE from the default value, you need to add '-s $GOOGLE_AUTH_FILE' here
GA_ARGS="-f -t -D -r 3 -R 30 -S 30 -w 9"

# Full command that runs google-authenticator with the configured arguments.
GA_CMD="google-authenticator $GA_ARGS"

#
# END of configuration section
#

# LOG: script entry point
logger -t mfa-enroll "START enrollment script: user=${USER:-unknown} uid=$EUID shell=$SHELL tty=$(tty 2>/dev/null) pid=$$ flags=$-"

# Do not enforce MFA for root
[ "$EUID" -eq 0 ] && return

# Do not force enrollment in switched sessions (su/sudo)
# If loginuid is set and differs from current EUID, this is not a fresh login.
loginuid="$(cat /proc/self/loginuid 2>/dev/null)"
if [ -n "$loginuid" ] && [ "$loginuid" != "4294967295" ] && [ "$loginuid" != "$EUID" ]; then
  return
fi

# Enrollment Phase tracking variable
ENROLL_PHASE="pre"

# If user is in no-mfa or optional-mfa, do not force enrollment (MFA remains voluntary via PAM nullok)
groups="$(id -nG 2>/dev/null)" || groups=""
case " $groups " in
  *" $NO_MFA_GROUP "*|*" $OPTIONAL_MFA_GROUP "*) return ;;
esac

# Already enrolled
if [ -f "$GOOGLE_AUTH_FILE" ]; then
  logger -t mfa-enroll "User already enrolled, skipping enrollment: user=${USER:-$(id -un 2>/dev/null)}"
  return
fi

# If NOT enrolled + SSH context + NON-interactive shell => kill session (scp/sftp, forced command, etc.)
case $- in
  *i*)
    # interactive: allow (do enrollment later)
    ;;
  *)
    if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
      logger -t mfa-enroll "DENY (not enrolled): Non-interactive SSH session terminated: user=${USER:-unknown} flags=$- tty=$(tty 2>/dev/null) pid=$$"
      kill -HUP "$$" 2>/dev/null
      exit 1
    fi
    # non-interactive but not SSH: do nothing
    return
    ;;
esac

# Ensure required commands exist
command -v google-authenticator >/dev/null 2>&1 || return
if [ -n "$TIMEOUT_CMD" ]; then
  command -v timeout >/dev/null 2>&1 || return
fi

_wait_for_key() {
  if [ -t 0 ]; then
    echo
    echo "Press any key to continue..."
    read -r -n 1 -s
    echo
  fi
}

_mfa_abort() {
  if [ "$ENROLL_PHASE" = "post" ]; then
    kill -HUP "$$" 2>/dev/null
    exit
  fi

  logger -t mfa-enroll "ABORTED MFA enrollment (Ctrl+C) for user=${USER:-$(id -un 2>/dev/null)}"
  echo
  echo "MFA enrollment was aborted."
  echo "You will now be logged out."
  echo
  _wait_for_key
  kill -HUP "$$" 2>/dev/null
  exit
}
trap _mfa_abort INT TERM QUIT TSTP

U="${USER:-$(id -un 2>/dev/null)}"

echo
echo "MFA enrollment is required for SSH access."
echo "Starting Multi-Factor setup now (timeout: ${TIMEOUT}s)..."
echo

logger -t mfa-enroll "Starting MFA enrollment: user=$U flags=$- tty=$(tty 2>/dev/null) pid=$$"

# Track enrollment phase for signal handling
ENROLL_PHASE="enrolling"

if [ -n "$TIMEOUT_CMD" ]; then
  $TIMEOUT_CMD $GA_CMD
else
  $GA_CMD
fi
rc=$?

# From here on, enrollment attempt is finished; Ctrl+C should not say "aborted enrollment"
ENROLL_PHASE="post"

if [ "$rc" -eq 0 ]; then
  logger -t mfa-enroll "Completed MFA enrollment for user=$U"
  echo
  echo "MFA enrollment completed."
  echo "You will now be logged out. Please log in again to verify MFA."
  echo
elif [ "$rc" -eq 124 ]; then
  logger -t mfa-enroll "TIMED OUT MFA enrollment for user=$U"
  echo
  echo "MFA enrollment timed out."
  echo "You will now be logged out. Please log in again and complete enrollment."
  echo
else
  logger -t mfa-enroll "FAILED MFA enrollment (rc=$rc) for user=$U"
  echo
  echo "MFA enrollment failed (rc=$rc)."
  echo "You will now be logged out."
  echo
fi

_wait_for_key
kill -HUP "$$" 2>/dev/null
exit
