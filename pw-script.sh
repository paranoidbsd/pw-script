#!/bin/sh -
# Copyright (c) 2015, Joerg Pernfuss <code+github@paranoidbsd.net>
# All rights reserved
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted providing that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
# IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#
_specfile=${1:?'Mandatory specification input file missing'}
_altroot=${2:=''} # optional
_tmp=${TMPDIR:-${TMP:-${TEMP:-'/tmp'}}} # yes, this works! awesome?!

# sysexits(3)
EX_OK=0
EX_ERROR=1
EX_NOINPUT=66
EX_CANTCREAT=73
EX_NOPERM=77
_exit=$EX_OK

#
save_and_disable_stderr () {
  exec 6>&2 2>/dev/null
}

#
restore_stderr () {
  exec 2>&6 6>&-
}

# print error message to STDERR
error () {
  local _err=$1

  printf '%s\n' "$_err" >&2
}

# root required
check_uid () {
  if [ `id -u` -ne 0 ]; then
    restore_stderr
    error 'root access required.'
    exit EX_NOPERM
  fi
}

#
resolve_specfile_path () {
  local _err _in
  _in="$_specfile"

  _specfile=`realpath "$_specfile"`

  if [ -z "$_specfile" ]; then
    _err="Specification $_in does not exist"
  fi

  if [ -z "$_err" -a ! -f "$_specfile" ]; then
    _err="Specification $_specfile is not a file"
  fi

  if [ -z "$_err" -a ! -r "$_specfile" ]; then
    _err="Specification $_specfile is not readable"
  fi

  if [ -n "$_err" ]; then
    restore_stderr
    error "$_err"
    exit EX_NOINPUT
  fi
}

#
check_tmp_writeable () {
  local _err _in
  _in="$_tmp"

  _tmp=`realpath "$_tmp"`
  if [ -z "$_tmp" ]; then
    _err="Temporary path $_in does not exist"
  fi

  if [ -z "$_err" -a ! -d "$_tmp" ]; then
    _err="Path $_tmp is not a directory"
  fi

  if [ -z "$_err" -a ! -w "$_tmp" ]; then
    _err="Path $_tmp is not writable"
  fi

  if [ -z "$_err" -a ! -x "$_tmp" ]; then
    _err="Can not access directory $_tmp"
  fi

  if [ -n "$_err" ]; then
    restore_stderr
    error "$_err"
    exit EX_CANTCREAT
  fi
}

#
setup_altroot_etcdir () {
  local _err _in

  if [ -z "$_altroot" ]; then
    return
  fi

  _in="$_altroot"
  _altroot=`realpath "$_altroot"`

  if [ -z "$_altroot" ]; then
    _err="Altroot $_in does not exist"
  fi

  if [ -z "$_err" -a ! -d "$_altroot/etc" ]; then
    _err="$_altroot/etc is not a directory"
  fi

  if [ -z "$_err" -a ! -w "$_altroot/etc" ]; then
    _err="$_altroot/etc is not writable"
  fi

  if [ -n "$_err" ]; then
    restore_stderr
    error "$_err"
    exit EX_NOINPUT
  fi

  _etcdir="-V $_altroot/etc"
}

#
setup_fifo () {
  # `mkfifo` will fail if `mktemp -d` failed
  _tmpd=`mktemp -d ${_tmp}/XXXXXXXXXXXX`
  _fifo=`mktemp -u ${_tmpd}/XXXXXXXXXXXX`
  mkfifo -m 600 $_fifo
  if [ $? -ne 0 ]; then
    rmdir $_tmpd
    restore_stderr
    error "Error creating FIFO: ${_fifo:-'<undef>'}"
    exit EX_CANTCREAT
  fi
  exec 5<>$_fifo
}

#
cleanup_fifo () {
  exec 5<&- 5>&-
  rm $_fifo
  rmdir $_tmpd
}

#
get_home_path () {
  local __u=$1
  local __ret=$2
  local __p

  # Construct the homepath inside $_altroot, as determined by
  # pw.conf. Ensure required slashes, then fold in duplicates.
  # realpath is not used here since this function is also used to
  # build the path that will be created
  if pw $_etcdir usershow -n $__u >/dev/null; then
    __p=`pw $_etcdir usershow -n $__u | cut -d: -f9`
    __p=`printf '%s' "/${_altroot}/${__p}" | tr -s /`
  else
    __p=''
  fi
  eval $__ret="'$__p'"
}

#
get_user_ugid () {
  local __u=$1
  local __ret=$2
  local __val

  # Get the numeric ids from inside $_altroot, the username may not be
  # known outside of it, or using different ids
  if pw $_etcdir usershow -n $__u >/dev/null; then
    __val=`pw $_etcdir usershow -n $__u | cut -d: -f3-4`
  else
    __val=''
  fi
  eval $__ret="'$__val'"
}

#
copy_authorized_keys () {
  local __u=$1 # user
  local __k=${2:-''} # authorized_keys
  local __h __id

  # skip the rest if no authorized_keys specified
  if [ -z "$__k" ]; then
    return
  fi

  # Get user's home directory. Skip if user does not exist
  get_home_path $__u __h
  if [ -z "$__h" ]; then
    return
  fi

  # Preexisting users may have /nonexistent configured, which is invalid
  # even if it exists. Skip in that case.
  if printf '%s' "$__h" | grep '/nonexistent' >/dev/null; then
    return
  fi

  # realpath to verify the home actually exists
  __h=`realpath "$__h"`
  if [ -z "$__h" -o ! -d "$__h" ]; then
    return
  fi

  # Again, get the correct ids
  get_user_ugid $__u __id
  if [ -z "$__id" ]; then
    return
  fi

  # Copy authorized_keys file
  if [ -f "$__k" -a -r "$__k" ]; then
    mkdir -p "$__h/.ssh"
    chmod 0750 "$__h/.ssh"
    chown $__id "$__h/.ssh"

    cp "$__k" "$__h/.ssh/authorized_keys"
    chmod 0640 "$__h/.ssh/authorized_keys"
    chown $__id "$__h/.ssh/authorized_keys"
  fi
}

#
manually_create_user_home () {
  local __u=$1
  local __skel __dot __id __nf __h

  # Retrieve home and id information
  get_home_path $__u __h
  if [ -z "$__h" ]; then
    return
  fi

  get_user_ugid $__u __id
  if [ -z "$__id" ]; then
    return
  fi

  # Create the home directory
  mkdir -p "$__h"
  __h=`realpath "$__h"`
  chmod 0750 "$__h"
  chown $__id "$__h"

  # If there is a pw.conf with a skeleton directive, use it
  if grep '^skeleton' "$_altroot/etc/pw.conf" >/dev/null; then
    __skel=`grep '^skeleton' "$_altroot/etc/pw.conf" |\
      awk '{ print $2 }'`
    __skel="/$_altroot/$__skel"
  fi
  : ${__skel:="/$_altroot/usr/share/skel"}
  __skel=`realpath "$__skel"`

  # Skip if the directory does not exist
  if [ -z "$__skel" -o ! -d "$__skel" ]; then
    return
  fi

  # Copy the skeleton files
  for __dot in ${__skel}/*; do
    # Skip things that are not files
    if [ ! -f "$__dot" ]; then
      continue
    fi

    __nf=`basename $__dot | sed -e 's/^dot//'`
    cp $__dot "$__h/$__nf"
    chmod 0640 "$__h/$__nf"
    chown $__id "$__h/$__nf"
  done
}

# Main
save_and_disable_stderr
check_uid
resolve_specfile_path
check_tmp_writeable
setup_altroot_etcdir
: ${_etcdir:=''}
setup_fifo

# read and slice the datafile
while IFS=: read _user _key _group _hash; do
  # skip comment lines, where the # will end up in $_user
  case $_user in \#*) continue ;; esac

  # Skip entries where username or hash is missing
  if [ -z "$_user" -o -z "$_hash" ]; then
    _exit=$EX_ERROR
    continue
  fi

  # Setup variables if a grouplist was specified
  if [ -n "$_group" ]; then
    _gr_list=`printf '%s' "$_group" | tr -s ' ' | tr ' ' ,`
    _gr_list="-G $_gr_list"
    _gr_merge=`printf '%s' "$_group" | tr -s , | tr , ' '`
  fi

  # user exists: set password hash, merge groups and
  # copy authorized_keys
  if pw $_etcdir usershow -n $_user >/dev/null; then
    pw $_etcdir usermod -n $_user -H 5 &
    printf '%s\n' $_hash >&5
    wait

    for _g in ${_gr_merge:-''}; do
      pw $_etcdir groupmod -n $_g -m $_user
    done

    copy_authorized_keys $_user ${_key:-''}
    continue
  fi

  # skip if a group with the name of the requested new user already
  # exists
  if pw $_etcdir groupshow -n $_user >/dev/null; then
    _exit=$EX_ERROR
    continue
  fi

  # user does not exist, we need to create it
  # we have no altroot specified, pw can create the user's home
  # directory for us
  if [ -z "$_altroot" ]; then
    pw $_etcdir useradd -n $_user \
      ${_gr_list:-''} \
      -m -M 700 -s 'tcsh' -H 5 &
    printf '%s\n' $_hash >&5
    wait
  # if called with -V, pw will not create home directories, so we have
  # to do that. Specify shell with full path to avoid lookups outside
  # of $_altroot
  else
    pw $_etcdir useradd -n $_user \
      ${_gr_list:-''} \
      -s '/bin/tcsh' -H 5 &
    printf '%s\n' $_hash >&5
    wait

    manually_create_user_home $_user
  fi

  copy_authorized_keys $_user ${_key:-''}
done < "$_specfile"

# Close FIFO
cleanup_fifo

# Restore STDERR and close
restore_stderr
exit $_exit
