#!/usr/bin/env perl

=encoding utf8

=head1 NAME

blokus.pl - Stylize photos of Blokus boards

=head1 SYNOPSIS

    $ perl blokus.pl cropped/28.09.2022.jpg               # pretty display on TTY
    $ perl blokus.pl cropped/28.09.2022.jpg >board.txt    # machine-readable text
    $ perl blokus.pl cropped/28.09.2022.jpg board.png     # stylized image

=cut

use utf8;
use open qw(:std :utf8);
use lib 'lib';

use Modern::Perl 2018;
use Scalar::Util qw(openhandle);

use MPI::Blokus::Filters;
use MPI::Blokus::Colors;

use Path::Tiny qw(tempfile);
use Image::Magick;

=head1 DESCRIPTION

This program is part of the showcase of Blokus games played at the
MPI-MiS Leipzig.

Its job is to read a cropped photograph of a Blokus board and to detect
the color (or absence) of each tile on the board. It can output the board
in machine-readable form or as a synthesized image.

The heavy image processing part of this process has, unforunately, a
relatively long list of big dependencies. We need G'MIC, Gimp and the
Perl interface to ImageMagick, as well as a few CPAN modules.

=head2 Processing pipeline

The photograph is analyized in three steps:

=over

=item

First some heavy G'MIC filters are applied to the image to
smudge out flares and increase the saturation and clarity of colors.

=item

Next, Gimp's interpolation-less scaling algorithm is used to
downscale the image to a pixelated 20x20 image, such that each pixel
corresponds to a tile on the Blokus board. Since the tiles on the
board in the B<cropped> photo are aligned with the pixel grid, each
pixel's color is close to the tile's perceptive color in the photo.

=item

A k-means clustering algorithm runs on these 20x20 pixels and
decides which of them is red, green, blue, yellow or white.

=back

One this data is obtained, it can be output in either machine-readable
plain text (if no filename is given and the standard output is not a
TTY), or as a pretty colored board (if no filename is given and the
standard output B<is> a TTY), or as a stylized image if a filename is
given as command-line argument.

=cut

sub info {
    warn '** ', @_, "\n";
}

my $src = shift // die 'need input image file';
my $dst = shift // *STDOUT;

info 'Applying filters...';
$src = apply_filters($src => tempfile(SUFFIX => '.png'));

info 'Scaling down...';
$src = scale_down($src => tempfile(SUFFIX => '.png'));

info 'Clustering colors...';
my $board = cluster_colors($src, progress => sub{
    my $delta = shift;
    info "Color clustering delta = $delta...";
    return $delta < 0.01;
});

if (not defined(openhandle $dst)) {
    info "Output to file $dst";
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
    # the horizontal and vertical separators from it.
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
elsif (-t $dst) {
    sub colorize {
        use Term::ANSIColor;
        my $c = shift;
        state $h = { R => 'red', G => 'green', B => 'blue', Y => 'yellow', W => 'white' };
        colored(" $c", 'bold', 'on_bright_' . $h->{$c})
    }

    info 'Output to TTY';
    for my $row (@$board) {
        say {$dst} join '', map colorize($_), @$row;
    }
}
else {
    info 'Plain output';
    for my $row (@$board) {
        say {$dst} join '', @$row;
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
