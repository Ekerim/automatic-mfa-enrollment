# Automatic MFA Enrollment
A simple /etc/profile.d/ script to facilitate enforcing Multi-Factor Authentication for SSH connections on Linux using Google Authenticator.

Designed and tested for use in OpenSSH / Thinlinc environments on RHEL based system, but should work on most Linux servers as long as they support `google-authenticator`.

The script blocks non-interactive SSH sessions (such as scp/sftp/ssh command/Thinlinc login) until the user connects to the server using an interactive SSH session which triggers the MFA enrollment procedure.

## Features
- Forces MFA enrollment through `google-authenticator` on any interactive SSH logins
- Rejects any non-interactive SSH sessions when the user has not enrolled
- The OS group `optional-mfa` can be added to a user to prevent forced enrollment, but still supports MFA if manually enrolled
- The OS group `no-mfa` can be used to opt-out a user completely from MFA
- `root` is never forced to enroll but supports MFA if enrolled, same as members of the `optional-mfa` group
- `su`/`sudo` does not trigger MFA enrollment
- Prevents escaping enrollment using Ctrl+C
- Logs progress of MFA enrollment process using `logger -t mfa-enroll`

## Requirements
- Bash-compatible login shell
- `google-authenticator` and `qrencode` installed on the system
- GNU `timeout` (from GNU coreutils) for enrollment deadlines
- SSH environments where interactive logins can be intercepted (OpenSSH, and optionally ThinLinc)

## Installation

RHEL based distros:
1. Install EPEL repository
    ```
    sudo dnf install epel-release -y
    ```
2. Install `qrencode`
    ```
    sudo dnf install qrencode -y
    ```
3. Install `google-authenticator`
    ```
    sudo dnf install google-authenticator -y
    ```
4. Copy `automatic-mfa-enrollment.sh` to `/etc/profile.d/` and make sure everyone has read permission
5. Configure `/etc/pam.d/sshd`.
    The auth section of my sshd PAM file looks like
    ```sh
    #%PAM-1.0
    auth       substack     password-auth

    # Skip MFA for any user that is a member of the no-mfa group.
    auth  [success=1 default=ignore] pam_succeed_if.so user ingroup no-mfa
    # Use MFA if enrolled (pam_google_authenticator.so) but also allow unenrolled users to log in (nullok)
    auth       required     pam_google_authenticator.so nullok try_first_pass

    auth       include      postlogin
    ... etc ...
    ```
    `pam_google_authenticator.so` is what triggers the use of MFA at login.
    `nullok` is required to allow that first unenrolled login that lets users enroll, but also facilitates the `optional-mfa` functionality
6. Add a file, `/etc/ssh/sshd_config.d/10-mfa-split.conf`, with the following content.
    ```sh
    UsePAM yes

    PubkeyAuthentication yes

    # Force “password logins” to go through PAM (so you get password + TOTP)
    PasswordAuthentication no
    KbdInteractiveAuthentication yes
    ChallengeResponseAuthentication yes

    # Either: key-only  OR  PAM interactive (password + TOTP)
    AuthenticationMethods publickey keyboard-interactive
    ```
    Make sure the settings you just added are not overridden by another file in the same directory. On RHEL derived systems, the file `50-redhat.conf`
    contains some of the same settings and you are recommended to comment them out so as to not interfere with what you just added in step 6.
7. Restart sshd
    ```
    systemctl restart sshd
    ```

MFA login and automatic enrollment should now be working.

### Customization
There is some customization that can be done in the script, but not much.
```sh
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
```

## Usage
During an SSH login:

- If a user is not already enrolled (`~/.google_authenticator` missing), the script allows the interactive shell to continue and triggers the `google-authenticator` tool with a timeout
- Non-interactive SSH connections (scp/sftp and forced commands, etc.) from unenrolled users are terminated immediately to prevent bypassing MFA
- Users in `NO_MFA_GROUP`/`OPTIONAL_MFA_GROUP` or sessions where the effective UID differs from `loginuid` (e.g., `su`/`sudo`) bypass the enforcement
- If the user is already enrolled, the script returns as soon as possible
 
## Testing / Verification
- Create a user on the server but do not enroll it.
- Try to connect to the user using `sftp`. This should fail after password prompt.
    ```
    ~> sftp user@host
    Password:
    Connection closed.
    Connection closed
    ```
- Try to transfer a file to the user using `scp`. This should fail after password prompt.
    ```
    ~> scp file.dat user@host:.
    Password:
    lost connection
    ```
- Try to execute a command on the host as the user. Nothing should be displayed after password prompt.
    ```
    ~> ssh user@host "hostname"
    Password:
    ```
- Log in as root and `su` to the test users account.
    ```
    [root@host ~]# su - user
    Last login: Thu Jan 22 10:07:01 CET 2026 on pts/0
    [user@host ~]$ 
    ```
    Notice that the enrollment process does not start.
- Enroll the user by opening an interactive SSH connection to the user and follow the instructions.
    This should log you out once the enrollment process is finished and ask you to test it by logging in again.
- SSH to the test users account.
    ```
    ~> ssh user@host
    Password:
    Verification code:
    Last login: Thu Jan 22 10:28:32 2026
    [user@host ~]$
    ```
    During login you will be asked enter an MFA verification code. Once that is completed you should have access to your shell as usual.
- As the test user, create an ssh key and test it.
    ```
    [user@host ~]$ mkdir ~/.ssh
    [user@host ~]$ chmod 700 ~/.ssh
    [user@host ~]$ cd ~/.ssh
    [user@host ~/.ssh]$ ssh-keygen -t ed25519
    ... truncated ...
    [user@host ~/.ssh]$ cat id_ed25519.pub >> authorized_keys
    [user@host ~/.ssh]$ chmod 644 ./authorized_keys
    [user@host ~/.ssh]$ ssh user@host
    Last login: Thu Jan 22 10:35:11 2026
    [user@host ~]$ 
    ```
    Notice that you were not asked for an MFA verification code when using public key authentication.

## Troubleshooting
- Check that `google-authenticator` and `timeout` exist in `PATH`.
- Review `logger -t mfa-enroll` output for the failure reason.

## Contributing
Issues and pull requests are welcome; describe your environment and how you verified changes.

## License
This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
