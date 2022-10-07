=encoding utf8

=head1 NAME

MPI::Blokus::Filters - Image manipulation and filters

=head1 SYNOPSIS

    use Path::Tiny qw(tempfile);
    my $dst = apply_filters($src => tempfile);
    my $dst = scale_down($src => tempfile);

=cut

# ABSTRACT: Image manipulation and filters
package MPI::Blokus::Filters;

use Modern::Perl 2018;
use Export::Attrs;

use IPC::Run3;
use MPI::Blokus::Data::Loader;

=head1 DESCRIPTION

This module encapsulates calling the external programs G'MIC and Gimp to preprocess
the input photographs.

=head2 Exportable subs

=head3 apply_filters :Export(:DEFAULT)

    my $dst = apply_filters($src, $dst);

Apply a predefined set of G'MIC filters to amplify colors and blur the
image to hopefully reduce flares from the photograph.

=cut

sub apply_filters :Export(:DEFAULT) {
    my ($src, $dst) = @_;
    my $script = data_file('filters.gmic');
    run3 ['gmic', '-input', $src, '-m', $script, '-blokus_filters', '-output', $dst], \$script, \my $out, \my $err;
    die "gmic failed with status @{[ $? >> 8 ]}.\nOutput: $out\nError: $err\n"
        unless $? == 0;
    $dst
}

=head2 scale_down :Export

    my $dst = scale_down($src, $dst);

Scale the image down to a 20x20 pixel grid, using Gimp's python scripting
interface. The downscaling uses no interpolation and produces a strongly
pixelated result, which is what we want.

=cut

sub scale_down :Export(:DEFAULT) {
    my ($src, $dst) = @_;
    my $script = data_file('scale_down.py');
    $script =~ s/__SRC__/$src/g;
    $script =~ s/__DST__/$dst/g;

    run3 ['gimp', '-sdfi', '--batch-interpreter=python-fu-eval', '-b', '-'], \$script, \my $out, \my $err;
    die "gimp failed with status @{[ $? >> 8 ]}.\nOutput: $out\nError: $err\n"
        unless $? == 0;
    $dst
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
@@ filters.gmic
blokus_filters:
  jl_colorgrading 0,0,2,1,0,0,0,0,0,-20,1,1,0,0,70,0,0,0,0,0,70,180,0,1,0,0,0
  fx_smooth_meancurvature 40,40,0,0,0,24,0,50,50
  fx_smooth_median_preview 30,255,0,0,50,50
@@ scale_down.py
src = "__SRC__"
dst = "__DST__"
img = pdb.gimp_file_load(src, src)
pdb.gimp_context_set_interpolation(0)
pdb.gimp_image_scale(img, 20, 20)
pdb.gimp_file_save(img, img.layers[0], dst, dst)
pdb.gimp_image_delete(img)
pdb.gimp_quit(1)
