#!/usr/bin/env perl

=encoding utf8

=head1 NAME

blokus.pl - Stylize photos of Blokus boards

=head1 SYNOPSIS

    $ perl blokus.pl [--filtered=file] [--scaled=file] [--color-table=file] infile [outfile]

For example:

    $ perl blokus.pl cropped/28.09.2022.jpg               # pretty display on TTY
    $ perl blokus.pl cropped/28.09.2022.jpg >board.txt    # machine-readable text
    $ perl blokus.pl cropped/28.09.2022.jpg board.png     # stylized image

=cut

use utf8;
use open qw(:std :utf8);
use lib 'lib';

use Modern::Perl 2018;
use Getopt::Long;
use Pod::Usage;

use MPI::Blokus::Filters;
use MPI::Blokus::Colors qw(cluster_colors :color);

use Try::Tiny;
use Path::Tiny qw(tempfile);

=head2 OPTIONS

=over

=item B<--filtered>=I<file>

The output of the filtering step is stored in this file. By default, this
is a temporary file and removed at program exit.

=item B<--scaled>=I<file>

The output of the scaling step is stored in this file. By default, this
is a temporary file and removed at program exit.

=item B<--color-table>=I<file>

The color clustering algorithm produces a table of five colors which are
the reference values of red, green, blue, yellow and white for the the image.
Use this option to specify a location where this table should be rendered
as an image consisting of five 50x50 solidly colored squares.

=back

=cut

GetOptions(
    'h|help'        => \my $help,
    'filtered=s'    => \my $filtered_file,
    'scaled=s'      => \my $scaled_file,
    'color-table=s' => \my $color_table_file,
) or pod2usage(2);

pod2usage(-exitval => 0, -verbose => 1) if $help;

=head1 DESCRIPTION

This program is part of the showcase of Blokus games played at the
MPI-MiS Leipzig.

Its job is to read a cropped photograph of a Blokus board and to detect
the color (or absence) of each tile on the board. It can output the board
in machine-readable form or as a synthesized image.

The heavy image processing part of this process has, unforunately, a
relatively long list of big dependencies. We need G'MIC, Gimp and the
Perl interface to ImageMagick, as well as a few CPAN modules.

=cut

sub info {
    warn '** ', @_, "\n";
}

my $infile  = shift // pod2usage(2);
my $outfile = shift;

$filtered_file //= tempfile(SUFFIX => '.png');
$scaled_file   //= tempfile(SUFFIX => '.png');

=head2 Processing pipeline

The photo is analyzed in three steps:

=over

=item

First some heavy G'MIC filters are applied to the image to smudge out
glares and increase the saturation and clarity of the colors.

=cut

info 'Applying filters...';
apply_filters($infile => $filtered_file);

=item

Next, Gimp's interpolation-less scaling algorithm is used to
downscale the image to a pixelated 20x20 image, such that each pixel
corresponds to a tile on the Blokus board. Since the tiles on the
board in the B<cropped> photo are aligned with the pixel grid, each
pixel's color is close to the tile's perceptive color in the photo.

=cut

info 'Scaling down...';
scale_down($filtered_file => $scaled_file);

=item

A k-means clustering algorithm runs on these 20x20 pixels and
decides which of them is red, green, blue, yellow or white.

=back

=cut

info 'Clustering colors...';
my ($board, @centers) = cluster_colors($scaled_file, progress => sub{
    my $delta = shift;
    info "Color clustering delta = $delta...";
    return $delta < 0.01;
});

OUTPUT_COLOR_TABLE: {
if (defined $color_table_file) {
    if (not try { require Image::Magick; 1 }) {
        info 'Did not find Image::Magick, cannot output color table';
        last OUTPUT_COLOR_TABLE;
    }

    sub colored_block {
        my ($rgb, $w, $h) = @_;
        my $block = Image::Magick->new(size => $w . 'x' . $h);
        $block->ReadImage(sprintf 'canvas:#%02x%02x%02x', map 255*$_, @$rgb);
        $block
    }

    my $img = Image::Magick->new;
    push @$img, colored_block($_, 50, 50)->@* for @centers;
    $img->Append(stack => 'false')->Write($color_table_file);
}}

=head2 Output formats

Once this data is obtained, it can be output in three possible ways,
depending on the optional I<outfile> argument and the nature of the
standard output stream:

=cut

sub plain_output {
    my ($board, $dst) = @_;
    for my $row (@$board) {
        say {$dst} join '', @$row;
    }
}

sub tty_output {
    sub colorize {
        my $c = shift;
        state $h = { R => 'red', G => 'green', B => 'blue', Y => 'yellow', W => 'white' };
        Term::ANSIColor::colored(" $c", 'bold', 'on_bright_' . $h->{$c})
    }

    my ($board, $dst) = @_;
    for my $row (@$board) {
        say {$dst} join '', map colorize($_), @$row;
    }
}

sub image_output {
    my ($board, $dst) = @_;
    my $h = @$board;
    my $w = $board->[0]->@*;

    my $tile = Image::Magick->new;
    $tile->Read('res/tile.png');
    my ($th, $tw) = $tile->Get('height', 'width');

    sub colorized {
        my ($tile, $color) = @_;
        my $ctile = $tile->Clone;
        $ctile->Colorize(fill => $color, blend => '50/50/50');
        $ctile
    }

    sub white_tile {
        my $tile = shift;
        my ($h, $w) = $tile->Get('height', 'width');
        my $ctile = Image::Magick->new;
        $ctile->ReadImage('granite:');
        $ctile->Crop($w . 'x' . $h . '+0+0');
        $ctile->Colorize(fill => '#ffffff', blend => '20/20/20');
        $ctile
    }

    my %tile = (
        R => colorized($tile, '#ff0000'),
        G => colorized($tile, '#00b060'),
        B => colorized($tile, '#0000ff'),
        Y => colorized($tile, '#ffff00'),
        W => white_tile($tile),
    );

    my $seph = int($tw / 15);
    my $sepw = ($w * $tw + ($w+1) * $seph);
    # Make a massive granite block which is sufficiently big to cut out
    # the horizontal and vertical separators from.
    my $granite = do {
        my $gr = Image::Magick->new;
        $gr->ReadImage('granite:');
        my $tmp = Image::Magick->new;
        for (0 .. int($seph / $gr->Get('height'))) {
            my $row = Image::Magick->new;
            for (0 .. int($sepw / $gr->Get('width'))) {
                push @$row, $gr->Clone->@*;
            }
            push @$tmp, $row->Append(stack => 'false')->@*;
        }
        $tmp->Append(stack => 'true')
    };

    my $hsep = Image::Magick->new;
    push @$hsep, $granite->Clone->@*;
    $hsep->Crop($seph . 'x' . $th . '+0+0');
    $hsep->Colorize(fill => '#444444', blend => '50/50/50');

    my $vsep = Image::Magick->new;
    push @$vsep, $granite->Clone->@*;
    $vsep->Crop($sepw . 'x' . $seph . '+0+0');
    $vsep->Colorize(fill => '#444444', blend => '50/50/50');

    my $imgrows = Image::Magick->new;
    push @$imgrows, $vsep->Clone->@*;
    for my $y (0 .. $board->$#*) {
        my $imgrow = Image::Magick->new;
        my $row = $board->[$y];
        push @$imgrow, $hsep->Clone->@*;
        for my $x (0 .. $row->$#*) {
            my $ctile = $tile{ $board->[$y][$x] };
            push @$imgrow, $ctile->Clone->@*;
            push @$imgrow, $hsep->Clone->@*;
        }
        push @$imgrows, $imgrow->Append(stack => 'false')->@*;
        push @$imgrows, $vsep->Clone->@*;
    }
    $imgrows->Append(stack => 'true')->Write($dst);
}

=over

=item *

If an I<outfile> is given, then an image version of the board is synthesized
into this file. The image format is deduced (by ImageMagick) from the file
extension.

=item *

If no I<outfile> is given and stdout is not a terminal (for example it is
redirected into a file), then the format is machine-readable plain text
consisting of 20 rows of 20 letters from C<RGBYW> corresponding to the
colors red, green, blue, yellow and white.

=item *

If no I<outfile> is given but stdout B<is> connected to a terminal B<and>
the module C<Term::ANSIColor> is installed, then the plain text output
described above is prettified with terminal colors and each letter has a
space next to it, to make it visually more square.

=back

=cut

if (defined $outfile) {
    if (not try { require Image::Magick; 1 }) {
        info 'Did not find Image::Magick, falling back to plain output';
        plain_output($board => *STDOUT);
    }
    else {
        info "Output to file $outfile";
        image_output($board => $outfile);
    }
}
elsif (not -t *STDOUT) {
    info 'Plain output';
    plain_output($board => *STDOUT);
}
else {
    if (not try { require Term::ANSIColor; 1 }) {
        info 'Did not find Term::ANSIColor, falling back to plain output';
        plain_output($board => *STDOUT);
    }
    else {
        info 'Output to TTY';
        tty_output($board => *STDOUT);
    }
}

info 'Done!';

=head1 AUTHOR

Tobias Boege <tobs@taboege.de>

=head1 COPYRIGHT AND LICENSE

This software is copyright (C) 2022 by Tobias Boege.

This is free software; you can redistribute it and/or
modify it under the terms of the Artistic License 2.0.

=cut
