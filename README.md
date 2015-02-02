Script FreeBSD useraccounts with pw(8)
======================================

This repo contains an example script how to script user
accounts on FreeBSD using `pw(8)`. The script is called
like this:

```
./pw-script.sh userspecification [altroot]
```

`userspecification` is the input file for the script.
`altroot` is an optional second parameter to specify a
path where an alternate file hierarchy exists.

This can be used to add some initial users to a new system
from within an mfsBSD based deployment (new system mounted
under `/mnt`), or to a fresh jail (`/jail/foobar`).

The specification file format is:
* lines starting with `#` are comments
* one record per line
* every record contains 4 fields, separated by `:`
  * username
  * path to authorized_keys file [optional]
  * grouplist [optional]
  * password hash
* unset optional fields are empty, not skipped

The script uses a named pipe (FIFO) in a temporary directory to
pass the password hashes to `pw(8)`. This was actually the
initial motivation to write this script, most examples on the
net simply pipe it over STDIN. It kind of grew from there...

The temporary directory is by default created as a subdirectory
of `/tmp`. This can be overridden by setting one of the following
three environment variables, which are evaluated in the listed
order:
* `TMPDIR`
* `TMP`
* `TEMP`
The first variable that is set is chosen.

Entries in the specification file where either username or password
hash are empty are skipped.

username
--------

The username to work on. If the user already exists is checked
via `pw usershow`. For existing users, the password hash is
set.

If the username does not yet exist, but a group does exist
with the same name as the user, then the entry is skipped.

New users are created with `/bin/tcsh` as their shell and
a personal group with the same name as primary group.

authorized keys
---------------

If an authorized keys file is specified, it is copied into
the user's `~/.ssh`, replacing any eventually existing file.

This must be a path that represents the location of the file
at the time the script is running.

If the user's home is set to `/nonexistent`, this step is
skipped.

grouplist
---------

If a grouplist is specified, a new user's secondary groups
are set to those. For existing users, they are added to those
groups but not removed from existing ones.

These groups are not set up by the script. Multiple groups may
be specified, separated either by `,` or space.

password hash
-------------

The password hash to set for the user. Use `*` if the user
should not have a password. Any format recognized by FreeBSD will
work, but anything other than blf or sha256/512 hashes should
bring your root access into question.

Example Workflow
================

An example workflow for a custom mfsBSD could look like this:

1. Generate a public/private keypair.
    ```
    openssl genpkey \
      -genparam \
      -algorithm EC \
      -pkeyopt ec_paramgen_curve:sect571k1 \
      -out ecp.pem
    openssl genpkey \
      -aes256 \
      -paramfile ecp.pem \
      -out priv.pem \
      -outform PEM
    rm ecp.pem
    openssl ec \
      -in priv.pem \
      -pubout \
      -out pub.pem
    ```
    
2. Create tarball containing a pw.conf if needed, the userspec
   file and the authorized keys files. Sign it with the created
   private key.
    ```
    tar cJf datafile.txz ....
    openssl dgst \
      -sha256 \
      -sign priv.pem \
      -out datafile.txz.sig \
      datafile.txz
    ```
    
3. Put the tarball and the signature somewhere your mfsBSD can reach
   it. Put the public key in your mfsBSD (please do not put it next
   to the datafile and the signature on the webserver. If this
   confuses you, think about it really long and hard).

4. From within your installation script, fetch the tarball and the
   signature. Verify it against the public key embedded in your
   image.
    ```
    _tmpdir=`mktemp -d /tmp/XXXXX`
    fetch -o $_tmpdir/datafile.txz http://../datafile.txz
    fetch -o $_tmpdir/datafile.txz.sig http://../datafile.txz.sig
    openssl dgst \
      -sha256 \
      -verify pub.pem \
      -signature $_tmpdir/datafile.txz.sig \
      $_tmpdir/datafile.txz
    ```
    
5. If the verification checks out, unpack the tarball. Copy the
   pw.conf into the new system. Create required tool groups referenced
   inside the userspec.
   Run the script.
   Note that the paths to the authorized_keys files inside the userspec
   must match the paths within the mfsBSD after unpacking the tarball.
   Therefor you must use some placeholder inside the specification
   that you can resolve for it to work with `mktemp`.
    ```
    tar xf $_tmpdir/datafile.txz -C $_tmpdir
    cp $_tmpdir/pw.conf /mnt/etc/
    sed -E -I '' -e 's|%%PATH%%|'$_tmpdir'|' $_tmpdir/userspec
    pw -V /mnt groupadd -n ... -g ...
    pw-script.sh $_tmpdir/userspec /mnt
    rm -r $_tmpdir
    ```

Exit Codes
==========

If everything went well, the script will exit with exit code `0`.

If an error occurs during setup, before any userdata is touched, the
script will exit with an exit code `>= 2`.

If one or more entries in the userspecification were skipped due to
being invalid etc, the script will exit with exit code `1`.
It will not tell you which entries it skipped. Apart from that, the
error messages should be sort of helpful in most cases.

Disclaimer
==========

This is a bootstrapping script example, not an enterprise usermanagement.
Adapt it to your environment.

This is code you downloaded from the internet and execute as root.
Read it before you execute it.

This script will not ask you whether or not you are sure. If you call
it without an altroot, and a root entry is defined, it will reset your
root account. No questions asked.

License
=======

2-Clause BSD.
