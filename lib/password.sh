# shellcheck shell=bash
# LAB_PASSWORD rules (sourced by lib/common.sh and deploy/gcp/lab-gcp).
# The password is the domain Administrator, sa and service account password of every lab VM.
# Windows complexity: 8 or more characters and 3 of the 4 classes upper case, lower case, digit,
# other. The lab also refuses ' " \ ` $ and white space (the password goes through bash, JSON,
# XML and sqlcmd -P '...' without escaping problems).
# shellcheck disable=SC2034  # used by the files that source this one
LAB_PASSWORD_PLACEHOLDER='<change me>'
# shellcheck disable=SC2034
LAB_PASSWORD_HELP="Set the lab password in lab.local.env (gitignored; lab.env keeps the placeholder):
    echo \"LAB_PASSWORD='YourPassw0rd-Here'\" >> lab.local.env
  Rules: 8 or more characters; 3 of: upper case, lower case, digit, other character;
  not ' \" \\ \` \$ or space; must not contain 'Administrator' or 'sqlsvc'.
  The password is baked into the base image, checkpoints and golden snapshots at build time:
  a lab built with another password needs a rebuild (MAKE.md)."

password_problem() { # PW -> prints the problem and returns 1; returns 0 when the password is valid
  local p=$1 n=0
  [[ -z $p || $p == "$LAB_PASSWORD_PLACEHOLDER" ]] && {
    echo "LAB_PASSWORD is not set (empty or the placeholder $LAB_PASSWORD_PLACEHOLDER)"
    return 1
  }
  ((${#p} >= 8)) || {
    echo "LAB_PASSWORD is shorter than 8 characters"
    return 1
  }
  [[ $p =~ [\'\"\\\`\$[:space:]] ]] && {
    echo "LAB_PASSWORD contains a character that the lab does not accept (' \" \\ \` \$ or white space)"
    return 1
  }
  local lp=${p,,}
  [[ $lp == *administrator* || $lp == *sqlsvc* ]] && {
    echo "LAB_PASSWORD contains an account name (Administrator or sqlsvc)"
    return 1
  }
  [[ $p =~ [A-Z] ]] && n=$((n + 1))
  [[ $p =~ [a-z] ]] && n=$((n + 1))
  [[ $p =~ [0-9] ]] && n=$((n + 1))
  [[ $p =~ [^A-Za-z0-9] ]] && n=$((n + 1))
  ((n >= 3)) || {
    echo "LAB_PASSWORD has only $n of the 4 character classes (needs 3)"
    return 1
  }
  return 0
}
