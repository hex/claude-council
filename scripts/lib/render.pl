#!/usr/bin/env perl
# ABOUTME: Dependency-free markdown renderer for the streaming pane (perl fallback)
# ABOUTME: Copied to render.sh when no Rich-capable Python exists; theme via COUNCIL_THEME_RESOLVED
# ANSI: 1=bold 3=italic 4=under 7=inverse 9=strikethrough
# 36=cyan 33=yellow 35=magenta 90=bright-black 96=bright-cyan 97=bright-white
my $theme  = $ENV{COUNCIL_THEME_RESOLVED} // 'unknown';
my $strong = $theme eq 'dark' ? '1;97' : $theme eq 'light' ? '1;30' : '1';
my $em     = $theme eq 'dark' ? '3;97' : $theme eq 'light' ? '3;30' : '3';
# Headings/table headers: bright cyan pops on dark but washes out on light,
# where plain cyan holds contrast (also the safe pick when unknown)
my $head   = $theme eq 'dark' ? '96' : '36';
# Muted text: faint borders/thinking, gray link URLs/rules/table separators, and
# dim H6 headings. ANSI 2 (faint) and 90 (bright-black) both wash out on a light
# background, so light remaps both to a dark-gray 256-color (240) that holds
# contrast; dark and unknown keep the raw codes (they read fine on a dark theme).
my $faint = $theme eq 'light' ? '38;5;240' : '2';
my $gray  = $theme eq 'light' ? '38;5;240' : '90';
my $in_code = 0;
my $in_think = 0;
my @table_buf;
my $had_header_sep = 0;
my $cols = `tput cols 2>/dev/null` || 80;
chomp $cols;
$cols = 80 if $cols !~ /^\d+$/ || $cols < 20;

sub apply_inline {
    my $s = shift;
    $s =~ s/`([^`]+)`/\033[7;33m$1\033[0m/g;
    $s =~ s/\[([^\]]+)\]\(([^)]+)\)/\033[4;36m$1\033[24m \033[${gray}m($2)\033[0m/g;
    $s =~ s/~~([^~]+)~~/\033[9m$1\033[29m/g;
    $s =~ s/\*\*([^*]+)\*\*/\033[${strong}m$1\033[0m/g;
    $s =~ s/(?<!\*)\*([^*]+)\*(?!\*)/\033[${em}m$1\033[0m/g;
    return $s;
}

sub visual_width {
    my $s = shift;
    $s =~ s/\033\[[\d;]*m//g;  # strip ANSI codes
    return length($s);
}

sub flush_table {
    return unless @table_buf;
    my @widths;
    for my $cells (@table_buf) {
        for my $i (0 .. $#$cells) {
            my $w = visual_width($cells->[$i]);
            $widths[$i] = $w if !defined $widths[$i] || $w > $widths[$i];
        }
    }
    # Borderless table: only inner separators (no left/right/top/bottom borders).
    my $sep_v = " \033[${gray}m│\033[0m ";
    my $hsep  = join("\033[${gray}m─┼─\033[0m",
                     map { "\033[${gray}m" . ("─" x $_) . "\033[0m" } @widths) . "\n";

    for my $row_idx (0 .. $#table_buf) {
        my $cells = $table_buf[$row_idx];
        my $is_header = ($row_idx == 0 && $had_header_sep);
        my @parts;
        for my $j (0 .. $#widths) {
            my $cell = $cells->[$j] // '';
            my $pad = ' ' x ($widths[$j] - visual_width($cell));
            if ($is_header) { push @parts, "\033[1;${head}m$cell\033[0m$pad"; }
            else            { push @parts, "$cell$pad"; }
        }
        print join($sep_v, @parts), "\n";
        print $hsep if $is_header && @table_buf > 1;
    }
    @table_buf = ();
    $had_header_sep = 0;
}

while (my $line = <STDIN>) {
    # Strip raw control bytes from untrusted model output before any styling, so
    # a smuggled escape (OSC title-set, CSI cursor/clear, etc.) can't drive the
    # terminal. Keep tab (\x09) and newline (\x0a); the read delimits on \n.
    $line =~ s/[\x00-\x08\x0b-\x1f\x7f]//g;

    # ----- Reasoning blocks -----
    if ($line =~ /^\s*<think>/) {
        flush_table();
        $in_think = 1;
        print "\033[${faint};3m▸ thinking\033[0m\n";
        next;
    }
    if ($line =~ /^\s*<\/think>/) {
        $in_think = 0;
        print "\033[${faint}m└─\033[0m\n";
        next;
    }
    if ($in_think) {
        next if $line =~ /^\s*$/;
        chomp(my $content = $line);
        my $wrap_cols = $cols - 4;  # reserve "│ " prefix + a margin
        while (length($content) > $wrap_cols) {
            my $break = rindex($content, ' ', $wrap_cols);
            $break = $wrap_cols if $break < 1;
            my $piece = substr($content, 0, $break);
            $content = substr($content, $break);
            $content =~ s/^\s+//;
            print "\033[${faint}m│\033[0m \033[${faint};3m$piece\033[0m\n";
        }
        print "\033[${faint}m│\033[0m \033[${faint};3m$content\033[0m\n";
        next;
    }

    # ----- Fenced code blocks -----
    if ($line =~ /^```(\w*)/) {
        flush_table();
        if ($in_code) { print "\033[33m└─────\033[0m\n"; $in_code = 0; }
        else          { print "\033[33m┌───── \033[0m\033[33;3m$1\033[0m\n"; $in_code = 1; }
        next;
    }
    if ($in_code) { print "\033[33m│\033[0m  $line"; next; }

    # ----- Tables — buffer rows, flush on first non-table line -----
    if ($line =~ /^\s*\|.*\|\s*$/) {
        # Separator row → marks the row above as header
        if ($line =~ /^\s*\|[\s\-:|]+\|\s*$/) {
            $had_header_sep = 1;
            next;
        }
        my $row = $line;
        chomp $row;
        $row =~ s/^\s*\|//;
        $row =~ s/\|\s*$//;
        my @cells = split /\s*\|\s*/, $row;
        s/^\s+|\s+$//g for @cells;
        $_ = apply_inline($_) for @cells;
        push @table_buf, \@cells;
        next;
    }
    flush_table();

    # ----- Non-table line: apply inline subs first, then block subs -----
    $line = apply_inline($line);
    $line =~ s/^###### (.*)$/\033[${faint};3m$1\033[0m/;
    $line =~ s/^##### (.*)$/\033[1;3m$1\033[0m/;
    $line =~ s/^#### (.*)$/\033[1m$1\033[0m/;
    $line =~ s/^### (.*)$/\033[1;36m$1\033[0m/;
    $line =~ s/^## (.*)$/\033[1;${head}m$1\033[0m/;
    $line =~ s/^# (.*)$/\033[1;7;${head}m $1 \033[0m/;
    $line =~ s/^(\s*)(\d+)\. /$1\033[36m$2.\033[0m /;
    $line =~ s/^(\s*)[-*] /$1\033[36m•\033[0m /;
    $line =~ s/^> (.*)$/\033[35m▌\033[0m \033[3m$1\033[0m/;
    $line =~ s/^---+$/\033[${gray}m──────────────────────────────\033[0m/;
    print $line;
}
flush_table();
