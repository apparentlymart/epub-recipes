#!/usr/bin/perl

use strict;
use warnings;

use Data::Dumper;
use Template;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use File::Temp qw(tempdir);
use FindBin;

my $input_dir = shift || die "Usage: makeepub.pl <input-dir> <output-file.epub>\n";
my $output_file = shift || "recipes.epub";
my $work_dir = tempdir( CLEANUP => 0 );
my $template_dir = $FindBin::Bin . '/templates';

my $tt = Template->new({
    INCLUDE_PATH => $template_dir,
});

my $next_recipe_idx = 0;

my @sections = ();

# Traverse the directory structure to find recipes to convert,
# and convert them building up information in @sections.
foreach my $dir (sort glob("$input_dir/*")) {
    next unless -d $dir;

    my $title = (split(/\//, $dir))[-1];

    my @chapters = ();

    my $section = {
        title => $title,
        chapters => \@chapters,
    };
    push @sections, $section;

    foreach my $file (sort glob("$dir/*.txt")) {
        next unless -f $file;

        my $idx = $next_recipe_idx++;
        my $fn = sprintf("recipe%03i.xhtml", $idx);
        my $xhtml_file = "$work_dir/$fn";

        my $title = transform_recipe_file( $file, $xhtml_file );

        push @chapters, {
            title => $title,
            file => $fn,
        };
    }
}

print Data::Dumper::Dumper(\@sections);

# Now build the output epub zip file.
{
    my $zip = Archive::Zip->new();

    # The mimetype file must be first and it must be uncompressed
    # to please the most pedantic of epub readers.
    {
        my $mimetype_member = $zip->addString('application/epub+zip', 'mimetype');
        $mimetype_member->desiredCompressionMethod(COMPRESSION_STORED);
    }

    # Add the container.xml file, which is always the same
    # since it just points at the content.opf file.
    $zip->addFile( "$template_dir/container.xml", 'META-INF/container.xml' );

    # Generate and add content.opf
    {
        my $work_file = "$work_dir/content.opf";
        $tt->process('content_opf.tt', { sections => \@sections }, $work_file );
        $zip->addFile( $work_file, "OEBPS/content.opf" );
    }

    # Generate and add toc.ncx
    {
        my $work_file = "$work_dir/toc.ncx";
        $tt->process('toc_ncx.tt', { sections => \@sections }, $work_file );
        $zip->addFile( $work_file, "OEBPS/toc.ncx" );
    }

    # Add the stylesheet
    $zip->addFile( "$template_dir/recipe.css", 'OEBPS/recipe.css' );

    # Now finally add all of the content files
    foreach my $section (@sections) {
        foreach my $chapter (@{$section->{chapters}}) {
            my $file = $chapter->{file};
            $zip->addFile( "$work_dir/$file", "OEBPS/$file" );
        }
    }

    my $result = $zip->writeToFileNamed( $output_file );
    unless ($result == AZ_OK) {
        die "Failed to write archive to $output_file\n";
    }

}


sub transform_recipe_file {
    my ($in_fn, $out_fn) = @_;

    open(my $in, "<:encoding(UTF-8)", $in_fn) or die "Can't open $in_fn for reading: $!";
    open(my $out, ">:encoding(UTF-8)", $out_fn) or die "Can't open $out_fn for reading: $!";

    my $title = undef;
    my $servings = undef;
    my @ingredients = ();
    my @steps = ();

    my @lines = <$in>;
    chomp @lines;

    $title = shift @lines;
    $servings = shift @lines if $lines[0];

    my $accum_list = undef;

    foreach my $l (@lines) {
        if (uc($l) eq 'INGREDIENTS') {
            $accum_list = \@ingredients;
        }
        elsif (uc($l) eq 'METHOD') {
            $accum_list = \@steps;
        }
        elsif ($l =~ /^\s*\*\s*(.*?)$/) {
            my $item = $1;
            if ($accum_list) {
                push @$accum_list, do_special_chars($item);
            }
        }
    }

    # Make sure there's always an even number of ingredients
    # to make life easier in the template.
    push @ingredients, '&nbsp;' if (scalar(@ingredients) % 2) == 1;

    #print "$title\n$servings\n";
    #print $_, "\n" for @steps;
    #print $_, "\n" for @ingredients;

    my $vars = {
        title => do_special_chars($title),
        servings => $servings ? do_special_chars($servings) : undef,
        ingredients => \@ingredients,
        steps => \@steps,
    };
    $tt->process('recipe.tt', $vars, $out);

    return $title;
}

sub do_special_chars {
    my ($str) = @_;

    $str =~ s!(\b\d+)dF(\b)!$1&deg;F$2!g;
    $str =~ s!(\b[\d/-]+)\s!$1&nbsp;!g;
    $str =~ s!(\b\d+)-(\d+\b)!$1&ndash;$2!g;
    $str =~ s!(\b)(\d)/(\d)(\b)!$1 . pretty_fraction($2, $3) . $4!eg;

    return $str;
}

sub pretty_fraction {
    my ($num, $den) = @_;

    my $k = "$num/$den";

    return {
        '1/4' => '&#188;',
        '1/2' => '&#189;',
        '3/4' => '&#190;',

        # These are not available in the fonts on the Nook :(
        #'1/3' => '&#8531;',
        #'2/3' => '&#8532;',
        #'1/5' => '&#8533;',
        #'2/5' => '&#8534;',
        #'3/5' => '&#8535;',
        #'4/5' => '&#8536;',
        #'1/6' => '&#8537;',
        #'5/6' => '&#8538;',
        #'1/8' => '&#8539;',
        #'3/8' => '&#8540;',
        #'5/8' => '&#8541;',
        #'7/8' => '&#8542;',
    }->{$k} || $k;
}

