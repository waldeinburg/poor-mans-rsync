# Poor mans rsync

A replacement for rsync written in bash, using scp. The intention is just to implement the
behaviour needed to deploy static pages to a remote server.

## Installation

Copy `remote_sync.sh` somewhere. The following assumes that you have in `PATH`, e.g.
`/usr/local/bin`.

## Usage

    remote_sync.sh [options] <src-folder> <host> <dest-folder>

Options:

- `--dry`: Just report what the script would have copied and deleted.
- `-v` or `--verbose`: Print additional information.
- `--debug`: Print even more information. Implying `--verbose`.
- `--overwrite-all`: Just copy all files, overwriting everything. Useful if the timestamp state on
the server is wrong or if updating lots of files (the normal behavior would be one scp
call for each file which is not very fast).

## Why

I like to use

    rsync -avuz --delete <folder> <host>:<folder>

to deploy static pages to my web server, avoiding unnecessary uploading. Then I got a new host where
the cheapest option did not include rsync. Solution: Write a script which does just about the same.

## License

Copyright © 2021 Daniel Lundsgaard Skovenborg

Distributed under the Eclipse Public License either version 1.0 or (at your option) any later
version.
