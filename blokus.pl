#!/usr/bin/env perl

# This software is copyright (C) 2022 by Tobias Boege <tobs@taboege.de>.
# 
# This is free software; you can redistribute it and/or modify it under the
# terms of the Artistic License 2.0. A copy of the license is available from
# <https://opensource.org/licenses/Artistic-2.0>.

# This file was written on a Sunday in October -- all of it. It would
# benefit from refactoring into neat, small modules and all that jazz.
# It is performant enough for the use case here but there are certainly
# some ugly warts.
#
# In particular, this script should be three scripts: (1) for producing
# the 20x20 color image, (2) for producing the the 20x20 textual description
# and (3) for turning that into an image or colorful text grid. Collecting
# the outputs of (1) over time would be helpful for finding very good
# starting centers for the color clustering.
#
# Unfortunately, this pipeline depends on three different image processors:
#
#   - G'MIC: for heavy image filters,
#   - Gimp (2.10): for its downscaling algorithm,
#   - ImageMagick: for various small operations.
#
# It would be REALLY nice to shorten this list!
#                                                       -- tobs, 02 Oct 2022

use utf8;
use open qw(:std :utf8);

use Modern::Perl 2018;
use Scalar::Util qw(openhandle);
use List::Util qw(min max sum0);
use List::MoreUtils qw(zip6 natatime);

use Path::Tiny qw(tempfile);
use IPC::Run3;
use Image::Magick;

sub info {
    warn '** ', @_, "\n";
}

# Apply some G'MIC filters to amplify colors and blur the image to hopefully
# reduce flares from the photograph.
sub apply_filters {
    my ($src, $dst) = @_;
    run3 [
        'gmic', '-input', $src, # '-m', 'update316.gmic',
        '-jl_colorgrading', '0,0,2,1,0,0,0,0,0,-20,1,1,0,0,70,0,0,0,0,0,70,180,0,1,0,0,0',
        '-fx_smooth_meancurvature', '40,40,0,0,0,24,0,50,50',
        '-output', $dst
    ], \undef, \my $out, \my $err;
    die "gmic failed with status @{[ $? >> 8 ]}.\nOutput: $out\nError: $err\n"
        unless $? == 0;
    $dst
}

# Scale the image down to a 20x20 pixel grid, using Gimp's python scripting
# interface. The downscaling uses no interpolation and produces a strongly
# pixelated result, which is what we want.
sub scale_down {
    my ($src, $dst) = @_;
    my $script = <<~END_OF_PYTHON;
        src = "$src"
        dst = "$dst"
        img = pdb.gimp_file_load(src, src)
        pdb.gimp_context_set_interpolation(0)
        pdb.gimp_image_scale(img, 20, 20)
        pdb.gimp_file_save(img, img.layers[0], dst, dst)
        pdb.gimp_image_delete(img)
        pdb.gimp_quit(1)
        END_OF_PYTHON
    run3 ['gimp', '-sdfi', '--batch-interpreter=python-fu-eval', '-b', '-'], \$script, \my $out, \my $err;
    die "gimp failed with status @{[ $? >> 8 ]}.\nOutput: $out\nError: $err\n"
        unless $? == 0;
    $dst
}

# Convert the 20x20 color image into a textual representation of the board
# using letters W (white), R (red), G (green), B (blue) and Y (yellow).
# This is done using k-means clustering with one cluster for each color.
# The centers are initialized to measured values from one of the photographs.
sub cluster_colors {
    my $src = shift;
    my $img = Image::Magick->new;
    $img->Read($src);
    my ($h, $w) = $img->Get('height', 'width');

    # Convert the entire image to L*a*b* color space.
    my @rgb3 = $img->GetPixels(height => $h, width => $w, y => 0, x => 0, map => 'RGB', normalize => 'true');
    my @Lab;
    my $it = natatime(3, @rgb3);
    while (my @c = $it->()) {
        push @Lab, rgb_to_cielab(@c);
    }

    # Initialize the clusters for R, G, B, Y, W to a human-selected sample
    # of these colors from the first image:
    #   Red:    rgb_to_cielab(0.85546, 0.00000, 0.01171)
    #   Green:  rgb_to_cielab(0.00000, 0.58593, 0.59765)
    #   Blue:   rgb_to_cielab(0.00000, 0.06640, 0.82031)
    #   Yellow: rgb_to_cielab(0.92968, 0.84375, 0.00000)
    #   White:  rgb_to_cielab(0.68359, 0.76953, 0.85546)
    # Note that in particular green is very far away from pure green.
    # It is a blue-green!
    my $r0 = [45.5435559005204, 71.2261901202121,   58.7990111487604];
    my $g0 = [55.99325296512,  -31.3180842362666,  -11.0554684962454];
    my $b0 = [26.7664119929502, 64.6007191380555,  -90.9469824994828];
    my $y0 = [85.3505967832022, -9.64103179963871,  85.2686011712401];
    my $w0 = [78.2795265950689, -2.77329146855748, -13.4132232950623];

    # Run k-means clustering around r0, g0, b0, y0, w0.
    my @board;
    my $delta = 1;
    while ($delta > 0.01) {
        my (@r, @g, @b, @y, @w);
        for my $i (0 .. $#Lab) {
            my ($dr, $dg, $db, $dy, $dw) =
                map color_distance($Lab[$i], $_), $r0, $g0, $b0, $y0, $w0;
            my $m = min($dr, $dg, $db, $dy, $dw);
            if ($m == $dr) {
                push @r, $Lab[$i];
                $board[$i] = 'R';
            }
            elsif ($m == $dg) {
                push @g, $Lab[$i];
                $board[$i] = 'G';
            }
            elsif ($m == $db) {
                push @b, $Lab[$i];
                $board[$i] = 'B';
            }
            elsif ($m == $dy) {
                push @y, $Lab[$i];
                $board[$i] = 'Y';
            }
            elsif ($m == $dw) {
                push @w, $Lab[$i];
                $board[$i] = 'W';
            }
            else {
                die '???';
            }
        }
        my ($r1, $g1, $b1, $y1, $w1) = map { avg(@$_) } [$r0,@r], [$g0,@g], [$b0,@b], [$y0,@y], [$w0,@w];
        $delta = sum0 map color_distance(@$_), [$r0,$r1], [$g0,$g1], [$b0,$b1], [$y0,$y1], [$w0,$w1];
        ($r0, $g0, $b0, $y0, $w0) = ($r1, $g1, $b1, $y1, $w1);
        info "Color clustering delta = $delta...";
    }

    # When the classification converged, we already have the board
    # stored in @board. Just spread it into an array of rows instead
    # of one long array, so that the caller doesn't need to know $w.
    my $bit = natatime($w, @board);
    my @res;
    while (my @row = $bit->()) {
        push @res, [@row];
    }
    [@res]
}

# (Squared) Euclidean distance of two color triples.
sub color_distance {
    my ($c1, $c2) = @_;
    sum0(map { ($_->[0] - $_->[1]) ** 2 } zip6 @$c1, @$c2)
}

# Average (baricenter) of given points.
sub avg {
    die 'no points given' unless @_;
    my $n = @_;
    my @p;
    for my $q (@_) {
        for my $i (0 .. $q->$#*) {
            $p[$i] += 1/$n * $q->[$i];
        }
    }
    [@p]
}

# Convert an RGB color triple to L*a*b* coordinates.
# Source: http://www.easyrgb.com/en/math.php
sub rgb_to_cielab {
    my ($r, $g, $b) = @_;
    $r = 100 * ($r > 0.04045 ? (($r + 0.055) / 1.055) ** 2.4 : $r / 12.92);
    $g = 100 * ($g > 0.04045 ? (($g + 0.055) / 1.055) ** 2.4 : $g / 12.92);
    $b = 100 * ($b > 0.04045 ? (($b + 0.055) / 1.055) ** 2.4 : $b / 12.92);

    my $x = $r * 0.4124 + $g * 0.3576 + $b * 0.1805;
    my $y = $r * 0.2126 + $g * 0.7152 + $b * 0.0722;
    my $z = $r * 0.0193 + $g * 0.1192 + $b * 0.9505;

    # Reference values: D65 (Daylight)
    $x /=  95.047;
    $y /= 100.000;
    $z /= 108.883;

    $x = $x > 0.008856 ? $x ** (1/3) : 7.787 * $x + 0.13793;
    $y = $y > 0.008856 ? $y ** (1/3) : 7.787 * $y + 0.13793;
    $z = $z > 0.008856 ? $z ** (1/3) : 7.787 * $z + 0.13793;

    my $L = 116 * $y - 16;
    my $A = 500 * ($x - $y);
    my $B = 200 * ($y - $z);

    [$L, $A, $B]
}

my $src = shift // die 'need input image file';
my $dst = shift // *STDOUT;

info 'Applying filters...';
$src = apply_filters($src => tempfile(SUFFIX => '.png'));

info 'Scaling down...';
$src = scale_down($src => tempfile(SUFFIX => '.png'));

info 'Clustering colors...';
my $board = cluster_colors($src);

if (not defined(openhandle $dst)) {
    info "Output to file $dst";
    my $h = @$board;
    my $w = $board->[0]->@*;

    my $tile = Image::Magick->new;
    $tile->Read('tile.png');
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
        G => colorized($tile, '#00ff00'),
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
