requires 'Modern::Perl', '>= 2018';
requires 'open';
requires 'utf8';
requires 'lib';

requires 'Getopt::Long';
requires 'Pod::Usage';

requires 'Export::Attrs';
requires 'Clone';

requires 'List::Util';
requires 'List::MoreUtils';
requires 'Path::Tiny';
requires 'Try::Tiny';

requires 'IPC::Run3';
requires 'Image::Magick';

recommends 'Term::ANSIColor';

on test => sub {
    requires 'Test::More';
}
