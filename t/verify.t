#!/usr/bin/env perl

use Modern::Perl 2018;
use Test::More;
use Path::Tiny;

my @files = path("verified")->children;
plan tests => 0+ @files;
for my $src (sort @files) {
    my $name = $src->basename(qr/.txt$/);
    my ($image,) = path("cropped")->children(qr/$name/);
    SKIP: {
        skip "could not find cropped image for $src" => 1
            if not defined $image;

        my $board = `perl blokus.pl "$image" 2>&-`;
        is $board, path($src)->slurp_utf8, "$name verified";
    }
}
