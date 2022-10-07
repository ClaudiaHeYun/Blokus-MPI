=encoding utf8

=head1 NAME

MPI::Blokus::Data::Loader - Load multiple files from __DATA__

=head1 SYNOPSIS

    # Named file from this package
    say data_file('file1.txt');
    # Named file from another package
    say data_file('Other::Package' => 'measurements.dat');

    # Unnamed file from this package
    say data_file;
    # Unnamed file from another package
    say data_file('Other::Package' => '');

    __DATA__
    @@ file1.txt
    the contents of file1
    on multiple lines

    @@ file2.txt
    yada yada yada

=cut

# ABSTRACT: Load multiple files from __DATA__
package MPI::Blokus::Data::Loader;

use Modern::Perl 2018;
use Export::Attrs;

=head1 DESCRIPTION

This module allows accessing multiple files from the __DATA__ section of
a package. It works almost like L<Mojo::Loader> but without pulling in
all the rest of Mojolicious as a dependency. It also does not support
base64-encoded files.

=head2 Exportable subs

=head3 data_file :Export(:DEFAULT)

    my $data    = data_file;                # single file
    my $named   = data_file('file1.txt');   # named file
    my $testset = data_file('My::Test::Data' => 'set1.dat'); # non-caller package

To make use of this module, your __DATA__ section must consist of embedded
files. Each embedded file starts off with a line of the form /^@@ (filename)/,
followed by a newline and the contents. Note that the /^@@/ pattern must not
appear in the file contents. There is currently no escaping mechanism.

For example:

    __DATA__
    This is the unnamed file
    @@ file1.txt
    First file with
    multiple lines
    @@ file2.txt
    and so on and so forth

The data before the first filename declaration is part of an unnamed file
that is internally stored under the empty filename.

These files can be accessed using the C<data_file> sub. It receives zero,
one or two arguments. Without any argument, it returns the unnamed file of
the current package (the caller of data_file). One argument is interpreted
as a filename relative to the current package. Two filenames are the
package whose DATA to read and then the filename.

The DATA of each read package is cached, it is never parsed twice.

=cut

my %CACHE;

sub _read_data {
    my $package = shift;
    my $data = do {
        no strict 'refs';
        local $.;
        my $fh = \*{"${package}::DATA"};
        my $data = join '', <$fh>;
        close $fh;
        $data
    };

    my ($unnamed, @files) = split /^@@\s*(.+?)\s*\r?\n/m, $data;
    my $c = { };
    $c->{''} = $unnamed;
    while (@files) {
        my ($name, $data) = splice @files, 0, 2;
        $c->{$name} = $data;
    }
    $c
}

sub data_file :Export(:DEFAULT) {
    my ($package, $filename) = @_ <= 1 ? (scalar caller, @_) : @_;
    $filename //= '';
    my $c = $CACHE{$package} //= _read_data($package);
    wantarray ? %$c : ($c->{$filename} // die "file not found in $package: '$filename'")
}

=head1 AUTHOR

Tobias Boege <tobs@taboege.de>

Some portions of this software and the general idea were taken from
L<Mojo::Loader>, Copyright (C) 2008-2020, Sebastian Riedel and others.

=head1 COPYRIGHT AND LICENSE

This software is copyright (C) 2020 by Tobias Boege.

This is free software; you can redistribute it and/or
modify it under the terms of the Artistic License 2.0.

=cut

":wq"
