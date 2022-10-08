=encoding utf8

=head1 NAME

MPI::Blokus::Colors - Color manipulation and detection

=head1 SYNOPSIS

    my $board = cluster_colors($src);

=cut

# ABSTRACT: Color manipulation and detection
package MPI::Blokus::Colors;

use Modern::Perl 2018;
use Export::Attrs;

use Clone qw(clone);
use List::Util qw(min max sum0);
use List::MoreUtils qw(zip6 natatime);
use Image::Magick;
use MPI::Blokus::Data::Loader;

=head1 DESCRIPTION

This module contains the k-means clustering algorithm which is used to
detect the color of tiles in a 20x20 pixel image, as produced by the
processing steps in C<MPI::Blokus::Filters>. The clustering function
C<cluster_colors> is exported by default.

The export tag C<:color> exports additional general-purpose color routines,
like RGB to L*a*b* color space conversion or (Euclidean) color distance.

=head2 Exportable subs

=head3 rgb_to_cielab :Export(:color)

    my ($L, $a, $b) = rgb_to_cielab($R, $G, $B);

Convert an RGB color triple to L*a*b* coordinates, as per
L<http://www.easyrgb.com/en/math.php> and using the D65 (Daylight)
reference values. Takes an array and returns an array.

=cut

sub rgb_to_cielab :Export(:color) {
    my ($R, $G, $B) = @_;
    $R = 100 * ($R > 0.04045 ? (($R + 0.055) / 1.055) ** 2.4 : $R / 12.92);
    $G = 100 * ($G > 0.04045 ? (($G + 0.055) / 1.055) ** 2.4 : $G / 12.92);
    $B = 100 * ($B > 0.04045 ? (($B + 0.055) / 1.055) ** 2.4 : $B / 12.92);

    my $X = $R * 0.4124 + $G * 0.3576 + $B * 0.1805;
    my $Y = $R * 0.2126 + $G * 0.7152 + $B * 0.0722;
    my $Z = $R * 0.0193 + $G * 0.1192 + $B * 0.9505;

    # Reference values: D65 (Daylight)
    $X /=  95.047;
    $Y /= 100.000;
    $Z /= 108.883;

    $X = $X > 0.008856 ? $X ** (1/3) : 7.787 * $X + 0.13793;
    $Y = $Y > 0.008856 ? $Y ** (1/3) : 7.787 * $Y + 0.13793;
    $Z = $Z > 0.008856 ? $Z ** (1/3) : 7.787 * $Z + 0.13793;

    my $L = 116 * $Y - 16;
    my $a = 500 * ($X - $Y);
    my $b = 200 * ($Y - $Z);

    ($L, $a, $b)
}

=head3 cielab_to_rgb :Export(:color)

    my ($R, $G, $B) = cielab_to_rgb($L, $a, $b);

Convert a L*a*b* color triple to RGB coordinates, as per
L<http://www.easyrgb.com/en/math.php> and using the D65 (Daylight)
reference values. Takes an array and returns an array.

=cut

sub cielab_to_rgb :Export(:color) {
    my ($L, $a, $b) = @_;

    my $Y = ($L + 16) / 116;
    my $X = $a / 500 + $Y;
    my $Z = $Y - $b / 200;

    $Y = $Y ** 3 > 0.008856 ? $Y ** 3 : ($Y - 0.13793) / 7.787;
    $X = $X ** 3 > 0.008856 ? $X ** 3 : ($X - 0.13793) / 7.787;
    $Z = $Z ** 3 > 0.008856 ? $Z ** 3 : ($Z - 0.13793) / 7.787;

    # Reference values: D65 (Daylight)
    $X *= 0.95047;
    $Y *= 1.00000;
    $Z *= 1.08883;

    my $R = $X *  3.2406 + $Y * -1.5372 + $Z * -0.4986;
    my $G = $X * -0.9689 + $Y *  1.8758 + $Z *  0.0415;
    my $B = $X *  0.0557 + $Y * -0.2040 + $Z *  1.0570;

    $R = $R > 0.0031308 ? 1.055 * $R ** 0.41666 - 0.055 : 12.92 * $R;
    $G = $G > 0.0031308 ? 1.055 * $G ** 0.41666 - 0.055 : 12.92 * $G;
    $B = $B > 0.0031308 ? 1.055 * $B ** 0.41666 - 0.055 : 12.92 * $B;

    ($R, $G, $B)
}

=head3 color_distance :Export(:color)

    my $d = color_distance($c1, $c2);

This function computes the square Euclidean distance of the two arrayrefs
which must have equal length. This may be used on color triplets in the
perceptually uniform L*a*b* color space to measure closeness.

=cut

sub color_distance :Export(:color) {
    my ($c1, $c2) = @_;
    sum0(map { ($_->[0] - $_->[1]) ** 2 } zip6 @$c1, @$c2)
}

=head3 avg :Export(:guts)

    my $c = avg(@points)

Compute the coordinate-wise average of all given points.

=cut

sub avg :Export(:guts) {
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

=head3 cluster_colors :Export(:DEFAULT)

    my ($board, @centers) = cluster_colors($src, progress => sub{...});

Convert a 20x20 pixel color image into a textual representation of the board
using letters R (red), G (green), B (blue), Y (yellow) and W (white). Colors
are classified using k-means clustering with one cluster for each color and
distance is determined in L*a*b* coordinates. The centers are initialized to
hard-coded, measured values from several of the photographs.

The return value C<$board> is an arrayref of 20 rows, each of which is an
arrayref of 20 items. Each item is one of the C<RGBYW> letters. Afterwards
the five color centers are returned in the order RGBYW, each as an RGB
triple inside an arrayref.

The optional argument C<progress> is a coderef which is called after every
iteration of the clustering algorithm with the argument C<$delta>, a float
value of how much in total the cluster centers moved. If this function
returns non-zero, then the clustering terminates. If it is not given,
iteration continues until C<< $delta < 0.01 >>.

=cut

sub cluster_colors :Export(:DEFAULT) {
    my $src = shift;
    my %opts = @_;
    my $progress = $opts{progress};

    my $img = Image::Magick->new;
    $img->Read($src);
    my ($h, $w) = $img->Get('height', 'width');

    # Convert the entire image to L*a*b* color space.
    my @rgb3 = $img->GetPixels(height => $h, width => $w, y => 0, x => 0, map => 'RGB', normalize => 'true');
    my @Lab;
    my $it = natatime(3, @rgb3);
    while (my @c = $it->()) {
        push @Lab, [rgb_to_cielab(@c)];
    }

    # Initialize the clusters for R, G, B, Y, W to the average of human-
    # selected samples from the first few images in their 20x20 form.
    my $r0 = clone state $_r0 = read_color_samples('red.txt');
    my $g0 = clone state $_g0 = read_color_samples('green.txt');
    my $b0 = clone state $_b0 = read_color_samples('blue.txt');
    my $y0 = clone state $_y0 = read_color_samples('yellow.txt');
    my $w0 = clone state $_w0 = read_color_samples('white.txt');

    # Run k-means clustering around r0, g0, b0, y0, w0.
    my @board;
    while (1) {
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
        my ($r1, $g1, $b1, $y1, $w1) = map avg(@$_), [@r], [@g], [@b], [@y], [@w];
        my $delta = sum0 map color_distance(@$_), [$r0,$r1], [$g0,$g1], [$b0,$b1], [$y0,$y1], [$w0,$w1];
        ($r0, $g0, $b0, $y0, $w0) = ($r1, $g1, $b1, $y1, $w1);

        if ($progress) {
            last if $progress->($delta);
        }
        else {
            last if $delta < 0.01;
        }
    }

    # When the classification converged, we already have the board
    # stored in @board. Just spread it into an array of rows instead
    # of one long array, so that the caller doesn't need to know $w.
    my $bit = natatime($w, @board);
    my @res;
    while (my @row = $bit->()) {
        push @res, [@row];
    }
    ([@res], map [cielab_to_rgb(@$_)], $r0, $g0, $b0, $y0, $w0)
}

# This function is internal. It reads the color sample files in the
# __DATA__ section. The format is compact to make it easy to add or
# remove samples.
#
# Each record consists of space-separated hexadecimal #rrggbb values.
# These values are averaged and returned as an L*a*b* arrayref.
sub read_color_samples {
    my $rgb = avg map {
        [map hex()/255, /#?(..)(..)(..)/]
    } split / /, data_file(shift);
    [rgb_to_cielab(@$rgb)]
}

=head1 AUTHOR

Tobias Boege <tobs@taboege.de>

=head1 COPYRIGHT AND LICENSE

This software is copyright (C) 2022 by Tobias Boege.

This is free software; you can redistribute it and/or
modify it under the terms of the Artistic License 2.0.

=cut

":wq"

__DATA__
@@ red.txt
#8b0003 #e20006 #c14857 #a30005 #d32240
@@ green.txt
#005d48 #00887a #00978d #00767b #00a5a7
@@ blue.txt
#00978d #2b4de0 #6c85e4 #0012a9 #0319d4
@@ yellow.txt
#b88c00 #dda800 #d4ce00 #e1ad00 #dae81d
@@ white.txt
#bab0be #c9c9cd #bebfc9 #a5c1d6 #b2b5cf
