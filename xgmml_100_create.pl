#!/usr/bin/env perl

BEGIN {
    die "Please load efishared before runing this script" if not $ENV{EFISHARED};
    use lib $ENV{EFISHARED};
}

#version 0.9.1 Changed to using xml creation packages (xml::writer) instead of writing out xml myself
#version 0.9.1 Removed dat file parser (not used anymore)
#version 0.9.1 Remove a bunch of commented out stuff
#version 0.9.2 no changes
#version 0.9.5 added an xml comment that holds the database name, for future use with gnns and all around good practice
#version 0.9.5 changed -log10E edge attribue to be named alignment_score

#this program creates an xgmml with all nodes and edges

use strict;

use List::MoreUtils qw{apply uniq any} ;
use DBD::mysql;
use IO;
use XML::Writer;
use XML::LibXML;
use Getopt::Long;
use FindBin;
use EFI::Config;
use EFI::Annotations;

my ($blast, $fasta, $struct, $output, $title, $maxfull, $dbver);
my $result=GetOptions ("blast=s"	=> \$blast,
    "fasta=s"	=> \$fasta,
    "struct=s"	=> \$struct,
    "output=s"	=> \$output,
    "title=s"	=> \$title,
    "maxfull=i"	=> \$maxfull,
    "dbver=s"	=> \$dbver);

die "Invalid command line arguments" if not $blast or not $fasta or not $struct or not $output or not $title or not $dbver;


if(defined $maxfull){
    unless($maxfull=~/^\d+$/){
        die "maxfull must be an integer\n";
    }
}else{
    $maxfull=10000000;
}


my ($edge, $node) = (0, 0);

my %sequence=();
my %uprot=();

my @uprotnumbers=();

my $blastlength=`wc -l $blast`;
my @blastlength=split( "\s+" , $blastlength);
if(int(@blastlength[0])>$maxfull){
    open(OUTPUT, ">$output") or die "cannot write to $output\n";
    chomp @blastlength[0];
    print OUTPUT "Too many edges (@blastlength[0]) not creating file\n";
    print OUTPUT "Maximum edges is $maxfull\n";
    exit;
}


my $parser=XML::LibXML->new();
my $output=new IO::File(">$output");
my $writer=new XML::Writer(DATA_MODE => 'true', DATA_INDENT => 2, OUTPUT => $output);

my $anno = new EFI::Annotations;

print time . " check length of 2.out file\n";





print time . " Reading in uniprot numbers from fasta file\n";

open(FASTA, $fasta) or die "could not open $fasta\n";
foreach my $line (<FASTA>){
    if($line=~/>([A-Za-z0-9:]+)/){
        push @uprotnumbers, $1;
    }
}
close FASTA;
print time . " Finished reading in uniprot numbers\n";

# Column headers and order in output file.
my @metas;
print time . " Read in annotation data\n";
#if struct file (annotation information) exists, use that to generate annotation information
if(-e $struct){
    print "populating annotation structure from file\n";
    open STRUCT, $struct or die "could not open $struct\n";
    my $id;
    foreach my $line (<STRUCT>){
        chomp $line;
        if($line=~/^([A-Za-z0-9\:]+)/){
            $id=$1;
        }else{
            my ($junk, $key, $value) = split "\t",$line;
            unless($value){
                $value='None';
            }
            next if not $key;
            push(@metas, $key) if not grep { $_ eq $key } @metas;
            if ($anno->is_list_attribute($key)) {
                my @tmpline = grep /\S/, split(",", $value);
                $uprot{$id}{$key} = \@tmpline;
            }else{
                $uprot{$id}{$key} = $value; 
            }
        }
    }
    close STRUCT;
}
print time . " done reading in annotation data\n";


if ($#metas < 0) {
    print time . " Open struct file and get a annotation keys\n";
    open STRUCT, $struct or die "could not open $struct\n";
    <STRUCT>;
    @metas=();
    while (<STRUCT>){
        last if /^\w/;
        my $line=$_;
        chomp $line;
        if($line=~/^\s/){
            my @parts = split /\t/, $line;
            push @metas, $parts[1];
        }
    }
}

my $annoData = EFI::Annotations::get_annotation_data();
@metas = EFI::Annotations::sort_annotations($annoData, @metas);

my $metaline=join ',', @metas;

print time ." Metadata keys are $metaline\n";
print time ." Start nodes\n";
$writer->comment("Database: $dbver");
$writer->startTag('graph', 'label' => "$title Full Network", 'xmlns' => 'http://www.cs.rpi.edu/XGMML');
foreach my $element (@uprotnumbers){
    #print "$element\n";;
    my $origelement=$element;
    $node++;
    $writer->startTag('node', 'id' => $element, 'label' => $element);
    if($element=~/(\w{6,10}):/){
        $element=$1;
    }
    foreach my $key (@metas){
        #print "\t$key\t$uprot{$element}{$key}\n";
        my $displayName = $annoData->{$key}->{display};
         if ($anno->is_list_attribute($key)) {
            $writer->startTag('att', 'type' => 'list', 'name' => $displayName);
            foreach my $piece (@{$uprot{$element}{$key}}){
                $piece=~s/[\x00-\x08\x0B-\x0C\x0E-\x1F]//g;
                $writer->emptyTag('att', 'type' => 'string', 'name' => $displayName, 'value' => $piece);
            }
            $writer->endTag();
        }else{
            $uprot{$element}{$key}=~s/[\x00-\x08\x0B-\x0C\x0E-\x1F]//g;
            my $piece = $uprot{$element}{$key};
            if($key eq "Sequence_Length" and $origelement=~/\w{6,10}:(\d+):(\d+)/){
                $piece=$2-$1+1;
                print "start:$1\tend$2\ttotal:$piece\n";
            }
            my $type = EFI::Annotations::get_attribute_type($key);
            if ($piece or $type ne "integer") {
                $writer->emptyTag('att', 'name' => $displayName, 'type' => $type, 'value' => $piece);
            }
#            }else{
#                if($key eq "Sequence_Length"){
#                    $writer->emptyTag('att', 'name' => $displayName, 'type' => 'integer', 'value' => $uprot{$element}{$key});
#                }else{
#                    $writer->emptyTag('att', 'name' => $displayName, 'type' => 'string', 'value' => $uprot{$element}{$key});
#                }
#            }
        }
    }
    $writer->endTag();
}

print time . " Writing Edges\n";
open BLASTFILE, $blast or die "could not open blast file $blast\n";
while (<BLASTFILE>){
    my $line=$_;
    $edge++;
    chomp $line;
    my @line=split /\t/, $line;
    #my $log=-(log(@line[3])/log(10))+@line[2]*log(2)/log(10);
    my $log=int(-(log(@line[5]*@line[6])/log(10))+@line[4]*log(2)/log(10));
    $writer->startTag('edge', 'id' => "@line[0],@line[1]", 'label' => "@line[0],@line[1]", 'source' => @line[0], 'target' => @line[1]);
    $writer->emptyTag('att', 'name' => '%id', 'type' => 'real', 'value' => @line[2]);
    $writer->emptyTag('att', 'name' => 'alignment_score', 'type'=> 'real', 'value' => $log);
    $writer->emptyTag('att', 'name' => 'alignment_len', 'type' => 'integer', 'value' => @line[3]);

    $writer->endTag();
}
close BLASTFILE;
print time . " Finished writing edges\n";
#print the footer
$writer->endTag;
print "finished writing xgmml file\n";
print "\t$node\t$edge\n";

