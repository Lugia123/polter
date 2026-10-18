//! The Chinese for each setting's help in Settings > All Options (task 1751):
//! the first paragraph, the line under a row (phase A), and the whole text
//! behind "More..." (phase B, `full_en`/`full_zh`, in batches).
//!
//! The English is Ghostty's own, generated from the `///` comments in
//! `Config.zig` (`help_strings`); it is not a msgid anywhere, so `xgettext`
//! cannot see it and this table stands in for a catalogue. `en` is the
//! paragraph the translation was made from, joined on single spaces. When the
//! comment is edited and `en` no longer equals it, `form.docZh` answers null
//! (the hosts fall back to the English) and the test in `form.zig` fails,
//! naming the key. A key is a field of `Config`, not a string, so a setting
//! renamed or removed stops this file compiling. Configuration names, values
//! and sample commands are kept as they are.

const std = @import("std");
const Config = @import("Config.zig");

pub const Key = std.meta.FieldEnum(Config);

pub const Entry = struct {
    key: Key,
    en: []const u8,
    zh: []const u8,
    /// The whole help text, as `help_strings` has it, and its Chinese with
    /// the same paragraphs and the same sample lines (phase B). Empty for a
    /// key whose help is one paragraph (`zh` is all of it) and for a key not
    /// translated in full yet; the hosts then show the English.
    full_en: []const u8 = "",
    full_zh: []const u8 = "",
};

pub const entries = [_]Entry{
    .{
        .key = .language,
        .en = "Set Ghostty's graphical user interface language to a language other than the system default language. For example:",
        .zh = "把 Ghostty 图形界面的语言设成系统默认语言以外的语言。例如：",
        .full_en =
        \\Set Ghostty's graphical user interface language to a language other than the
        \\system default language. For example:
        \\
        \\    language = de
        \\
        \\will force the strings in Ghostty's graphical user interface to be in German
        \\rather than the system default.
        \\
        \\This will not affect the language used by programs run _within_ Ghostty.
        \\Those will continue to use the default system language. There are also many
        \\non-GUI elements in Ghostty that are not translated - this setting will have
        \\no effect on those.
        \\
        \\Warning: This setting cannot be reloaded at runtime. To change the language
        \\you must fully restart Ghostty.
        \\
        \\GTK only.
        \\Available since 1.3.0.
        ,
        .full_zh =
        \\把 Ghostty 图形界面的语言设成系统默认语言以外的语言。例如：
        \\
        \\    language = de
        \\
        \\会强制 Ghostty 图形界面里的文字使用德语，而不是系统默认语言。
        \\
        \\这不会影响在 Ghostty 里运行的程序所用的语言，它们仍使用系统默认语言。Ghostty 里也有许多非图形界面的内容没有翻译，这项设置对它们没有效果。
        \\
        \\警告：这项设置不能在运行时重新加载。要更改语言，必须完全重启 Ghostty。
        \\
        \\仅 GTK。
        \\自 1.3.0 起可用。
        ,
    },
    .{
        .key = .@"font-family",
        .en = "The font families to use.",
        .zh = "使用的字体族。",
        .full_en =
        \\The font families to use.
        \\
        \\You can generate the list of valid values using the CLI:
        \\
        \\    ghostty +list-fonts
        \\
        \\This configuration can be repeated multiple times to specify preferred
        \\fallback fonts when the requested codepoint is not available in the primary
        \\font. This is particularly useful for multiple languages, symbolic fonts,
        \\etc.
        \\
        \\Notes on emoji specifically: On macOS, Ghostty by default will always use
        \\Apple Color Emoji and on Linux will always use Noto Emoji. You can
        \\override this behavior by specifying a font family here that contains
        \\emoji glyphs.
        \\
        \\The specific styles (bold, italic, bold italic) do not need to be
        \\explicitly set. If a style is not set, then the regular style (font-family)
        \\will be searched for stylistic variants. If a stylistic variant is not
        \\found, Ghostty will use the regular style. This prevents falling back to a
        \\different font family just to get a style such as bold. This also applies
        \\if you explicitly specify a font family for a style. For example, if you
        \\set `font-family-bold = FooBar` and "FooBar" cannot be found, Ghostty will
        \\use whatever font is set for `font-family` for the bold style.
        \\
        \\Finally, some styles may be synthesized if they are not supported.
        \\For example, if a font does not have an italic style and no alternative
        \\italic font is specified, Ghostty will synthesize an italic style by
        \\applying a slant to the regular style. If you want to disable these
        \\synthesized styles then you can use the `font-style` configurations
        \\as documented below.
        \\
        \\You can disable styles completely by using the `font-style` set of
        \\configurations. See the documentation for `font-style` for more information.
        \\
        \\If you want to overwrite a previous set value rather than append a fallback,
        \\specify the value as `""` (empty string) to reset the list and then set the
        \\new values. For example:
        \\
        \\    font-family = ""
        \\    font-family = "My Favorite Font"
        \\
        \\Setting any of these as CLI arguments will automatically clear the
        \\values set in configuration files so you don't need to specify
        \\`--font-family=""` before setting a new value. You only need to specify
        \\this within config files if you want to clear previously set values in
        \\configuration files or on the CLI if you want to clear values set on the
        \\CLI.
        ,
        .full_zh =
        \\使用的字体族。
        \\
        \\可以用命令行生成有效值的列表：
        \\
        \\    ghostty +list-fonts
        \\
        \\这项配置可以重复多次，用来指定备用字体：当主字体里没有所请求的码位时，会依次尝试这些字体。这对多语言、符号字体等特别有用。
        \\
        \\关于 emoji：在 macOS 上，Ghostty 默认始终使用 Apple Color Emoji；在 Linux 上始终使用 Noto Emoji。要改变这一行为，可以在这里指定一个含有 emoji 字形的字体族。
        \\
        \\具体的样式（粗体、斜体、粗斜体）不需要单独设置。某个样式没有设置时，会在常规样式（font-family）里查找它的样式变体；找不到样式变体，Ghostty 就使用常规样式。这样不会为了得到粗体之类的样式而改用另一个字体族。如果你为某个样式明确指定了字体族，这一点同样适用。例如，设置了 `font-family-bold = FooBar` 而找不到“FooBar”，Ghostty 会让粗体样式使用 `font-family` 所设的字体。
        \\
        \\最后，不受支持的样式可能会被合成。例如，字体没有斜体样式、又没有指定替代的斜体字体时，Ghostty 会给常规样式加上倾斜，合成出斜体样式。如果想禁用这些合成样式，可以使用下文所述的 `font-style` 配置。
        \\
        \\用 `font-style` 这组配置可以完全禁用某些样式。详见 `font-style` 的说明。
        \\
        \\如果想覆盖之前设置的值，而不是追加一个备用字体，就把值写成 `""`（空字符串）来重置列表，再设置新值。例如：
        \\
        \\    font-family = ""
        \\    font-family = "My Favorite Font"
        \\
        \\在命令行参数里设置这些项时，会自动清除配置文件里设置的值，所以在设置新值前不必先写 `--font-family=""`。只有在配置文件里想清除之前设置的值，或在命令行里想清除命令行上已设置的值时，才需要这样指定。
        ,
    },
    .{
        .key = .@"font-style",
        .en = "The named font style to use for each of the requested terminal font styles. This looks up the style based on the font style string advertised by the font itself. For example, \"Iosevka Heavy\" has a style of \"Heavy\".",
        .zh = "为终端请求的每种字体样式指定要用的命名字体样式。它按字体自己声明的样式名称查找。例如，“Iosevka Heavy”的样式是“Heavy”。",
        .full_en =
        \\The named font style to use for each of the requested terminal font styles.
        \\This looks up the style based on the font style string advertised by the
        \\font itself. For example, "Iosevka Heavy" has a style of "Heavy".
        \\
        \\You can also use these fields to completely disable a font style. If you set
        \\the value of the configuration below to literal `false` then that font style
        \\will be disabled. If the running program in the terminal requests a disabled
        \\font style, the regular font style will be used instead.
        \\
        \\These are only valid if its corresponding font-family is also specified. If
        \\no font-family is specified, then the font-style is ignored unless you're
        \\disabling the font style.
        ,
        .full_zh =
        \\为终端请求的每种字体样式指定要用的命名字体样式。它按字体自己声明的样式名称查找。例如，“Iosevka Heavy”的样式是“Heavy”。
        \\
        \\你也可以用这些项完全禁用某种字体样式：把下面的配置设成字面值 `false`，该字体样式就被禁用。终端里运行的程序请求被禁用的字体样式时，会改用常规字体样式。
        \\
        \\只有同时指定了对应的 font-family 才有效。没有指定 font-family 时，font-style 会被忽略，除非你是在禁用字体样式。
        ,
    },
    .{
        .key = .@"font-synthetic-style",
        .en = "Control whether Ghostty should synthesize a style if the requested style is not available in the specified font-family.",
        .zh = "当指定的 font-family 没有所请求的样式时，是否由 Ghostty 合成该样式。",
        .full_en =
        \\Control whether Ghostty should synthesize a style if the requested style is
        \\not available in the specified font-family.
        \\
        \\Ghostty can synthesize bold, italic, and bold italic styles if the font
        \\does not have a specific style. For bold, this is done by drawing an
        \\outline around the glyph of varying thickness. For italic, this is done by
        \\applying a slant to the glyph. For bold italic, both of these are applied.
        \\
        \\Synthetic styles are not perfect and will generally not look as good
        \\as a font that has the style natively. However, they are useful to
        \\provide styled text when the font does not have the style.
        \\
        \\Set this to "false" or "true" to disable or enable synthetic styles
        \\completely. You can disable specific styles using "no-bold", "no-italic",
        \\and "no-bold-italic". You can disable multiple styles by separating them
        \\with a comma. For example, "no-bold,no-italic".
        \\
        \\Available style keys are: `bold`, `italic`, `bold-italic`.
        \\
        \\If synthetic styles are disabled, then the regular style will be used
        \\instead if the requested style is not available. If the font has the
        \\requested style, then the font will be used as-is since the style is
        \\not synthetic.
        \\
        \\Warning: An easy mistake is to disable `bold` or `italic` but not
        \\`bold-italic`. Disabling only `bold` or `italic` will NOT disable either
        \\in the `bold-italic` style. If you want to disable `bold-italic`, you must
        \\explicitly disable it. You cannot partially disable `bold-italic`.
        \\
        \\By default, synthetic styles are enabled.
        ,
        .full_zh =
        \\当指定的 font-family 没有所请求的样式时，是否由 Ghostty 合成该样式。
        \\
        \\字体没有某个具体样式时，Ghostty 可以合成粗体、斜体和粗斜体。粗体是在字形外围描一圈粗细不等的轮廓；斜体是给字形加上倾斜；粗斜体则两者都用。
        \\
        \\合成的样式并不完美，通常不如字体自带的样式好看。但在字体没有该样式时，它们能提供带样式的文字。
        \\
        \\设成 "false" 或 "true"，可以完全禁用或启用合成样式。也可以用 "no-bold"、"no-italic" 和 "no-bold-italic" 禁用具体的样式，用逗号分隔可同时禁用多个，例如 "no-bold,no-italic"。
        \\
        \\可用的样式键有：`bold`、`italic`、`bold-italic`。
        \\
        \\禁用合成样式后，若所请求的样式不可用，就改用常规样式。字体自带所请求的样式时，会照常使用该字体，因为那不是合成样式。
        \\
        \\警告：一个容易犯的错误是只禁用了 `bold` 或 `italic`，却没有禁用 `bold-italic`。只禁用 `bold` 或 `italic`，并不会在 `bold-italic` 样式里禁用它们。要禁用 `bold-italic`，必须明确禁用它，不能只禁用它的一部分。
        \\
        \\默认启用合成样式。
        ,
    },
    .{
        .key = .@"font-feature",
        .en = "Apply a font feature. To enable multiple font features you can repeat this multiple times or use a comma-separated list of feature settings.",
        .zh = "启用一项字体特性。要启用多项，可重复写多次，或用逗号分隔的特性列表。",
        .full_en =
        \\Apply a font feature. To enable multiple font features you can repeat
        \\this multiple times or use a comma-separated list of feature settings.
        \\
        \\The syntax for feature settings is as follows, where `feat` is a feature:
        \\
        \\  * Enable features with e.g. `feat`, `+feat`, `feat on`, `feat=1`.
        \\  * Disabled features with e.g. `-feat`, `feat off`, `feat=0`.
        \\  * Set a feature value with e.g. `feat=2`, `feat = 3`, `feat 4`.
        \\  * Feature names may be wrapped in quotes, meaning this config should be
        \\    syntactically compatible with the `font-feature-settings` CSS property.
        \\
        \\The syntax is fairly loose, but invalid settings will be silently ignored.
        \\
        \\The font feature will apply to all fonts rendered by Ghostty. A future
        \\enhancement will allow targeting specific faces.
        \\
        \\To disable programming ligatures, use `-calt` since this is the typical
        \\feature name for programming ligatures. To look into what font features
        \\your font has and what they do, use a font inspection tool such as
        \\[fontdrop.info](https://fontdrop.info).
        \\
        \\To generally disable most ligatures, use `-calt, -liga, -dlig`.
        ,
        .full_zh =
        \\启用一项字体特性。要启用多项，可重复写多次，或用逗号分隔的特性列表。
        \\
        \\特性设置的语法如下，其中 `feat` 是某项特性：
        \\
        \\  * 启用特性，如 `feat`、`+feat`、`feat on`、`feat=1`。
        \\  * 禁用特性，如 `-feat`、`feat off`、`feat=0`。
        \\  * 设置特性的值，如 `feat=2`、`feat = 3`、`feat 4`。
        \\  * 特性名可以用引号括起来，也就是说这项配置在语法上应当与 CSS 的 `font-feature-settings` 属性兼容。
        \\
        \\语法相当宽松，但无效的设置会被悄悄忽略。
        \\
        \\这项字体特性会作用于 Ghostty 渲染的所有字体。以后会增加针对具体字面的能力。
        \\
        \\要禁用编程连字，用 `-calt`，因为这是编程连字的常见特性名。要了解你的字体有哪些特性、各有什么作用，可以用字体检查工具，如 [fontdrop.info](https://fontdrop.info)。
        \\
        \\要一般性地禁用大多数连字，用 `-calt, -liga, -dlig`。
        ,
    },
    .{
        .key = .@"font-size",
        .en = "Font size in points. This value can be a non-integer and the nearest integer pixel size will be selected. If you have a high dpi display where 1pt = 2px then you can get an odd numbered pixel size by specifying a half point.",
        .zh = "字号，单位为点（pt）。可以不是整数，实际会选用最接近的整数像素大小。如果你的高 DPI 显示器上 1pt = 2px，指定半个点就能得到奇数的像素大小。",
        .full_en =
        \\Font size in points. This value can be a non-integer and the nearest integer
        \\pixel size will be selected. If you have a high dpi display where 1pt = 2px
        \\then you can get an odd numbered pixel size by specifying a half point.
        \\
        \\For example, 13.5pt @ 2px/pt = 27px
        \\
        \\Changing this configuration at runtime will only affect existing
        \\terminals that have NOT manually adjusted their font size in some way
        \\(e.g. increased or decreased the font size). Terminals that have manually
        \\adjusted their font size will retain their manually adjusted size.
        \\Otherwise, the font size of existing terminals will be updated on
        \\reload.
        \\
        \\On Linux with GTK, font size is scaled according to both display-wide and
        \\text-specific scaling factors, which are often managed by your desktop
        \\environment (e.g. the GNOME display scale and large text settings).
        ,
        .full_zh =
        \\字号，单位为点（pt）。可以不是整数，实际会选用最接近的整数像素大小。如果你的高 DPI 显示器上 1pt = 2px，指定半个点就能得到奇数的像素大小。
        \\
        \\例如，13.5pt @ 2px/pt = 27px
        \\
        \\在运行时更改这项配置，只会影响没有手动调整过字号（例如放大或缩小）的现有终端。手动调整过字号的终端会保留它们手动调整后的大小。其余现有终端的字号会在重新加载时更新。
        \\
        \\在使用 GTK 的 Linux 上，字号会按显示器整体缩放和文字专用缩放两个系数缩放，它们通常由你的桌面环境管理（例如 GNOME 的显示缩放和大号文字设置）。
        ,
    },
    .{
        .key = .@"font-variation",
        .en = "A repeatable configuration to set one or more font variations values for a variable font. A variable font is a single font, usually with a filename ending in `-VF.ttf` or `-VF.otf` that contains one or more configurable axes for things such as weight, slant, etc. Not all fonts support variations; only fonts that explicitly state they are variable fonts will work.",
        .zh = "可重复的配置，为可变字体设置一个或多个字体变体值。可变字体是单个字体文件，文件名通常以 `-VF.ttf` 或 `-VF.otf` 结尾，含有一个或多个可调的轴，如字重、倾斜等。并非所有字体都支持变体；只有明确声明自己是可变字体的才有效。",
        .full_en =
        \\A repeatable configuration to set one or more font variations values for
        \\a variable font. A variable font is a single font, usually with a filename
        \\ending in `-VF.ttf` or `-VF.otf` that contains one or more configurable axes
        \\for things such as weight, slant, etc. Not all fonts support variations;
        \\only fonts that explicitly state they are variable fonts will work.
        \\
        \\The format of this is `id=value` where `id` is the axis identifier. An axis
        \\identifier is always a 4 character string, such as `wght`. To get the list
        \\of supported axes, look at your font documentation or use a font inspection
        \\tool.
        \\
        \\Invalid ids and values are usually ignored. For example, if a font only
        \\supports weights from 100 to 700, setting `wght=800` will do nothing (it
        \\will not be clamped to 700). You must consult your font's documentation to
        \\see what values are supported.
        \\
        \\Common axes are: `wght` (weight), `slnt` (slant), `ital` (italic), `opsz`
        \\(optical size), `wdth` (width), `GRAD` (gradient), etc.
        ,
        .full_zh =
        \\可重复的配置，为可变字体设置一个或多个字体变体值。可变字体是单个字体文件，文件名通常以 `-VF.ttf` 或 `-VF.otf` 结尾，含有一个或多个可调的轴，如字重、倾斜等。并非所有字体都支持变体；只有明确声明自己是可变字体的才有效。
        \\
        \\格式是 `id=value`，其中 `id` 是轴标识符。轴标识符总是 4 个字符的字符串，如 `wght`。要获得支持的轴列表，请查看字体文档或使用字体检查工具。
        \\
        \\无效的 id 和值通常会被忽略。例如，某个字体只支持 100 到 700 的字重，设置 `wght=800` 不会有任何效果（不会被限制到 700）。你必须查阅字体的文档，了解它支持哪些值。
        \\
        \\常见的轴有：`wght`（字重）、`slnt`（倾斜）、`ital`（斜体）、`opsz`（光学尺寸）、`wdth`（宽度）、`GRAD`（渐变）等。
        ,
    },
    .{
        .key = .@"font-codepoint-map",
        .en = "Force one or a range of Unicode codepoints to map to a specific named font. This is useful if you want to support special symbols or if you want to use specific glyphs that render better for your specific font.",
        .zh = "强制把一个或一段 Unicode 码位映射到指定名称的字体。想支持特殊符号，或想用在你的字体里显示更好的某些字形时，这很有用。",
        .full_en =
        \\Force one or a range of Unicode codepoints to map to a specific named font.
        \\This is useful if you want to support special symbols or if you want to use
        \\specific glyphs that render better for your specific font.
        \\
        \\The syntax is `codepoint=fontname` where `codepoint` is either a single
        \\codepoint or a range. Codepoints must be specified as full Unicode
        \\hex values, such as `U+ABCD`. Codepoints ranges are specified as
        \\`U+ABCD-U+DEFG`. You can specify multiple ranges for the same font separated
        \\by commas, such as `U+ABCD-U+DEFG,U+1234-U+5678=fontname`. The font name is
        \\the same value as you would use for `font-family`.
        \\
        \\This configuration can be repeated multiple times to specify multiple
        \\codepoint mappings.
        \\
        \\Changing this configuration at runtime will only affect new terminals,
        \\i.e. new windows, tabs, etc.
        ,
        .full_zh =
        \\强制把一个或一段 Unicode 码位映射到指定名称的字体。想支持特殊符号，或想用在你的字体里显示更好的某些字形时，这很有用。
        \\
        \\语法是 `codepoint=fontname`，其中 `codepoint` 是单个码位或一个范围。码位必须写成完整的 Unicode 十六进制值，如 `U+ABCD`。码位范围写成 `U+ABCD-U+DEFG`。同一个字体可以指定多个范围，用逗号分隔，如 `U+ABCD-U+DEFG,U+1234-U+5678=fontname`。字体名与 `font-family` 所用的值相同。
        \\
        \\这项配置可以重复多次，用来指定多组码位映射。
        \\
        \\在运行时更改这项配置，只会影响新的终端，即新的窗口、标签页等。
        ,
    },
    .{
        .key = .@"clipboard-codepoint-map",
        .en = "Map specific Unicode codepoints to replacement values when copying text to clipboard.",
        .zh = "复制文本到剪贴板时，把指定的 Unicode 码位映射为替换值。",
        .full_en =
        \\Map specific Unicode codepoints to replacement values when copying text
        \\to clipboard.
        \\
        \\This configuration allows you to replace specific Unicode characters with
        \\other characters or strings when copying terminal content to the clipboard.
        \\This is useful for converting special terminal symbols to more compatible
        \\characters for pasting into other applications.
        \\
        \\The syntax is similar to `font-codepoint-map`:
        \\- Single codepoint: `U+1234=U+ABCD` or `U+1234=replacement_text`
        \\- Codepoint range: `U+1234-U+5678=U+ABCD`
        \\
        \\Examples:
        \\- `clipboard-codepoint-map = U+2500=U+002D` (box drawing horizontal → hyphen)
        \\- `clipboard-codepoint-map = U+2502=U+007C` (box drawing vertical → pipe)
        \\- `clipboard-codepoint-map = U+03A3=SUM` (Greek sigma → "SUM")
        \\
        \\This configuration can be repeated multiple times to specify multiple
        \\mappings. Later entries take priority over earlier ones for overlapping
        \\ranges.
        \\
        \\Note: This only applies to text copying operations, not URL copying.
        ,
        .full_zh =
        \\复制文本到剪贴板时，把指定的 Unicode 码位映射为替换值。
        \\
        \\这项配置可以在复制终端内容到剪贴板时，把指定的 Unicode 字符替换成别的字符或字符串。这对把终端里的特殊符号转换成兼容性更好的字符、以便粘贴到其他应用里很有用。
        \\
        \\语法与 `font-codepoint-map` 类似：
        \\- 单个码位：`U+1234=U+ABCD` 或 `U+1234=replacement_text`
        \\- 码位范围：`U+1234-U+5678=U+ABCD`
        \\
        \\示例：
        \\- `clipboard-codepoint-map = U+2500=U+002D`（制表符横线 → 连字符）
        \\- `clipboard-codepoint-map = U+2502=U+007C`（制表符竖线 → 竖线符）
        \\- `clipboard-codepoint-map = U+03A3=SUM`（希腊字母西格玛 → "SUM"）
        \\
        \\这项配置可以重复多次，用来指定多组映射。范围重叠时，后面的条目优先于前面的。
        \\
        \\注意：这只作用于复制文本，不作用于复制 URL。
        ,
    },
    .{ .key = .@"font-thicken", .en = "Draw fonts with a thicker stroke, if supported. This is currently only supported on macOS.", .zh = "用更粗的笔画绘制字体（若支持）。目前只有 macOS 支持。" },
    .{
        .key = .@"font-thicken-strength",
        .en = "Strength of thickening when `font-thicken` is enabled.",
        .zh = "启用 `font-thicken` 时的加粗强度。",
        .full_en =
        \\Strength of thickening when `font-thicken` is enabled.
        \\
        \\Valid values are integers between `0` and `255`. `0` does not correspond to
        \\*no* thickening, rather it corresponds to the lightest available thickening.
        \\
        \\Has no effect when `font-thicken` is set to `false`.
        \\
        \\This is currently only supported on macOS.
        ,
        .full_zh =
        \\启用 `font-thicken` 时的加粗强度。
        \\
        \\有效值是 `0` 到 `255` 之间的整数。`0` 并不表示不加粗，而是表示可用的最轻的加粗。
        \\
        \\当 `font-thicken` 设为 `false` 时无效。
        \\
        \\目前只有 macOS 支持。
        ,
    },
    .{
        .key = .@"font-shaping-break",
        .en = "Locations to break font shaping into multiple runs.",
        .zh = "把字体整形拆成多段处理的位置。",
        .full_en =
        \\Locations to break font shaping into multiple runs.
        \\
        \\A "run" is a contiguous segment of text that is shaped together. "Shaping"
        \\is the process of converting text (codepoints) into glyphs (renderable
        \\characters). This is how ligatures are formed, among other things.
        \\For example, if a coding font turns "!=" into a single glyph, then it
        \\must see "!" and "=" next to each other in a single run. When a run
        \\is broken, the text is shaped separately. To continue our example, if
        \\"!" is at the end of one run and "=" is at the start of the next run,
        \\then the ligature will not be formed.
        \\
        \\Ghostty breaks runs at certain points to improve readability or usability.
        \\For example, Ghostty by default will break runs under the cursor so that
        \\text editing can see the individual characters rather than a ligature.
        \\This configuration lets you configure this behavior.
        \\
        \\Combine values with a comma to set multiple options. Prefix an
        \\option with "no-" to disable it. Enabling and disabling options
        \\can be done at the same time.
        \\
        \\Available options:
        \\
        \\  * `cursor` - Break runs under the cursor.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\把字体整形拆成多段处理的位置。
        \\
        \\“段”是一起整形的连续文本。“整形”是把文本（码位）转换成字形（可渲染的字符）的过程，连字就是这样形成的。例如，编程字体把 "!=" 变成一个字形，它就必须在同一段里同时看到相邻的 "!" 和 "="。段被拆开时，文本会分别整形。接着上面的例子，如果 "!" 在一段的末尾、"=" 在下一段的开头，连字就不会形成。
        \\
        \\Ghostty 会在某些位置拆段，以提高可读性或可用性。例如，Ghostty 默认在光标下方拆段，这样编辑文本时看到的是单个字符，而不是连字。这项配置可以设置这一行为。
        \\
        \\多个值用逗号连接可同时设置多个选项。在选项前加 "no-" 前缀可以禁用它。启用和禁用可以同时进行。
        \\
        \\可用的选项：
        \\
        \\  * `cursor` - 在光标下方拆段。
        \\
        \\自 1.2.0 起可用
        ,
    },
    .{
        .key = .@"alpha-blending",
        .en = "What color space to use when performing alpha blending.",
        .zh = "做 alpha 混合时使用的色彩空间。",
        .full_en =
        \\What color space to use when performing alpha blending.
        \\
        \\This affects the appearance of text and of any images with transparency.
        \\Additionally, custom shaders will receive colors in the configured space.
        \\
        \\On macOS the default is `native`, on all other platforms the default is
        \\`linear-corrected`.
        \\
        \\Valid values:
        \\
        \\* `native` - Perform alpha blending in the native color space for the OS.
        \\  On macOS this corresponds to Display P3, and on Linux it's sRGB.
        \\
        \\* `linear` - Perform alpha blending in linear space. This will eliminate
        \\  the darkening artifacts around the edges of text that are very visible
        \\  when certain color combinations are used (e.g. red / green), but makes
        \\  dark text look much thinner than normal and light text much thicker.
        \\  This is also sometimes known as "gamma correction".
        \\
        \\* `linear-corrected` - Same as `linear`, but with a correction step applied
        \\  for text that makes it look nearly or completely identical to `native`,
        \\  but without any of the darkening artifacts.
        \\
        \\Available since: 1.1.0
        ,
        .full_zh =
        \\做 alpha 混合时使用的色彩空间。
        \\
        \\这会影响文字和所有带透明度的图像的外观。此外，自定义着色器收到的颜色也在所配置的空间里。
        \\
        \\在 macOS 上默认是 `native`，其他所有平台默认是 `linear-corrected`。
        \\
        \\有效值：
        \\
        \\* `native` - 在操作系统的原生色彩空间里做 alpha 混合。在 macOS 上对应 Display P3，在 Linux 上是 sRGB。
        \\
        \\* `linear` - 在线性空间里做 alpha 混合。这会消除文字边缘的变暗瑕疵（在某些颜色搭配如红/绿时非常明显），但会让深色文字看起来比正常的细得多、浅色文字粗得多。这有时也叫“伽马校正”。
        \\
        \\* `linear-corrected` - 与 `linear` 相同，但对文字多做一步校正，使它看起来几乎或完全与 `native` 一样，同时没有任何变暗瑕疵。
        \\
        \\自 1.1.0 起可用
        ,
    },
    .{
        .key = .@"adjust-cell-width",
        .en = "All of the configurations behavior adjust various metrics determined by the font. The values can be integers (1, -1, etc.) or a percentage (20%, -15%, etc.). In each case, the values represent the amount to change the original value.",
        .zh = "这组配置都用来调整由字体决定的各项度量。值可以是整数（1、-1 等）或百分比（20%、-15% 等）。两种情况下，值都表示在原值上改变的量。",
        .full_en =
        \\All of the configurations behavior adjust various metrics determined by the
        \\font. The values can be integers (1, -1, etc.) or a percentage (20%, -15%,
        \\etc.). In each case, the values represent the amount to change the original
        \\value.
        \\
        \\For example, a value of `1` increases the value by 1; it does not set it to
        \\literally 1. A value of `20%` increases the value by 20%. And so on.
        \\
        \\There is little to no validation on these values so the wrong values (e.g.
        \\`-100%`) can cause the terminal to be unusable. Use with caution and reason.
        \\
        \\Some values are clamped to minimum or maximum values. This can make it
        \\appear that certain values are ignored. For example, many `*-thickness`
        \\adjustments cannot go below 1px.
        \\
        \\`adjust-cell-height` has some additional behaviors to describe:
        \\
        \\  * The font will be centered vertically in the cell.
        \\
        \\  * The cursor will remain the same size as the font, but may be
        \\    adjusted separately with `adjust-cursor-height`.
        \\
        \\  * Powerline glyphs will be adjusted along with the cell height so
        \\    that things like status lines continue to look aligned.
        ,
        .full_zh =
        \\这组配置都用来调整由字体决定的各项度量。值可以是整数（1、-1 等）或百分比（20%、-15% 等）。两种情况下，值都表示在原值上改变的量。
        \\
        \\例如，值 `1` 表示把原值加 1，而不是把它设成 1。值 `20%` 表示把原值增加 20%。依此类推。
        \\
        \\这些值几乎没有校验，所以错误的值（例如 `-100%`）可能让终端无法使用。请谨慎并合理地使用。
        \\
        \\有些值会被限制在最小值或最大值之内，这可能让某些值看起来被忽略了。例如，许多 `*-thickness` 调整不能低于 1px。
        \\
        \\`adjust-cell-height` 还有一些额外的行为：
        \\
        \\  * 字体会在单元格里垂直居中。
        \\
        \\  * 光标的大小仍与字体一致，但可以用 `adjust-cursor-height` 单独调整。
        \\
        \\  * Powerline 字形会随单元格高度一起调整，使状态栏之类的内容仍然对得整齐。
        ,
    },
    .{ .key = .@"adjust-font-baseline", .en = "Distance in pixels or percentage adjustment from the bottom of the cell to the text baseline. Increase to move baseline UP, decrease to move baseline DOWN. See the notes about adjustments in `adjust-cell-width`.", .zh = "文字基线到单元格底部的距离，单位为像素，或按百分比调整。调大使基线上移，调小使基线下移。关于调整的说明见 `adjust-cell-width`。" },
    .{ .key = .@"adjust-underline-position", .en = "Distance in pixels or percentage adjustment from the top of the cell to the top of the underline. Increase to move underline DOWN, decrease to move underline UP. See the notes about adjustments in `adjust-cell-width`.", .zh = "下划线顶部到单元格顶部的距离，单位为像素，或按百分比调整。调大使下划线下移，调小使下划线上移。关于调整的说明见 `adjust-cell-width`。" },
    .{ .key = .@"adjust-underline-thickness", .en = "Thickness in pixels of the underline. See the notes about adjustments in `adjust-cell-width`.", .zh = "下划线的粗细，单位为像素。关于调整的说明见 `adjust-cell-width`。" },
    .{ .key = .@"adjust-strikethrough-position", .en = "Distance in pixels or percentage adjustment from the top of the cell to the top of the strikethrough. Increase to move strikethrough DOWN, decrease to move strikethrough UP. See the notes about adjustments in `adjust-cell-width`.", .zh = "删除线顶部到单元格顶部的距离，单位为像素，或按百分比调整。调大使删除线下移，调小使删除线上移。关于调整的说明见 `adjust-cell-width`。" },
    .{ .key = .@"adjust-strikethrough-thickness", .en = "Thickness in pixels or percentage adjustment of the strikethrough. See the notes about adjustments in `adjust-cell-width`.", .zh = "删除线的粗细，单位为像素，或按百分比调整。关于调整的说明见 `adjust-cell-width`。" },
    .{ .key = .@"adjust-overline-position", .en = "Distance in pixels or percentage adjustment from the top of the cell to the top of the overline. Increase to move overline DOWN, decrease to move overline UP. See the notes about adjustments in `adjust-cell-width`.", .zh = "上划线顶部到单元格顶部的距离，单位为像素，或按百分比调整。调大使上划线下移，调小使上划线上移。关于调整的说明见 `adjust-cell-width`。" },
    .{ .key = .@"adjust-overline-thickness", .en = "Thickness in pixels or percentage adjustment of the overline. See the notes about adjustments in `adjust-cell-width`.", .zh = "上划线的粗细，单位为像素，或按百分比调整。关于调整的说明见 `adjust-cell-width`。" },
    .{ .key = .@"adjust-cursor-thickness", .en = "Thickness in pixels or percentage adjustment of the bar cursor and outlined rect cursor. See the notes about adjustments in `adjust-cell-width`.", .zh = "竖线光标和空心矩形光标的粗细，单位为像素，或按百分比调整。关于调整的说明见 `adjust-cell-width`。" },
    .{ .key = .@"adjust-cursor-height", .en = "Height in pixels or percentage adjustment of the cursor. Currently applies to all cursor types: bar, rect, and outlined rect. See the notes about adjustments in `adjust-cell-width`.", .zh = "光标的高度，单位为像素，或按百分比调整。目前对所有光标类型生效：竖线、矩形和空心矩形。关于调整的说明见 `adjust-cell-width`。" },
    .{ .key = .@"adjust-box-thickness", .en = "Thickness in pixels or percentage adjustment of box drawing characters. See the notes about adjustments in `adjust-cell-width`.", .zh = "制表符（方框绘制字符）的粗细，单位为像素，或按百分比调整。关于调整的说明见 `adjust-cell-width`。" },
    .{
        .key = .@"adjust-icon-height",
        .en = "Height in pixels or percentage adjustment of maximum height for nerd font icons.",
        .zh = "Nerd Font 图标最大高度的调整，单位为像素，或按百分比调整。",
        .full_en =
        \\Height in pixels or percentage adjustment of maximum height for nerd font icons.
        \\
        \\A positive (negative) value will increase (decrease) the maximum icon
        \\height. This may not affect all icons equally: the effect depends on whether
        \\the default size of the icon is height-constrained, which in turn depends on
        \\the aspect ratio of both the icon and your primary font.
        \\
        \\Certain icons designed for box drawing and terminal graphics, such as
        \\Powerline symbols, are not affected by this option.
        \\
        \\See the notes about adjustments in `adjust-cell-width`.
        \\
        \\Available in: 1.2.0
        ,
        .full_zh =
        \\Nerd Font 图标最大高度的调整，单位为像素，或按百分比调整。
        \\
        \\正值（负值）会增大（减小）图标的最大高度。这不一定对所有图标都有同样的效果：效果取决于图标的默认大小是否受高度限制，而这又取决于图标和你的主字体两者的宽高比。
        \\
        \\某些为制表符和终端图形设计的图标，如 Powerline 符号，不受这项配置影响。
        \\
        \\关于调整的说明见 `adjust-cell-width`。
        \\
        \\自 1.2.0 起可用
        ,
    },
    .{
        .key = .@"grapheme-width-method",
        .en = "The method to use for calculating the cell width of a grapheme cluster. The default value is `unicode` which uses the Unicode standard to determine grapheme width. This results in correct grapheme width but may result in cursor-desync issues with some programs (such as shells) that may use a legacy method such as `wcswidth`.",
        .zh = "计算字素簇单元格宽度的方法。默认值为 `unicode`，按 Unicode 标准确定字素宽度。这样得到的宽度是对的，但对一些仍用 `wcswidth` 等旧方法的程序（如 shell），可能造成光标错位。",
        .full_en =
        \\The method to use for calculating the cell width of a grapheme cluster.
        \\The default value is `unicode` which uses the Unicode standard to determine
        \\grapheme width. This results in correct grapheme width but may result in
        \\cursor-desync issues with some programs (such as shells) that may use a
        \\legacy method such as `wcswidth`.
        \\
        \\Valid values are:
        \\
        \\* `legacy` - Use a legacy method to determine grapheme width, such as
        \\  wcswidth This maximizes compatibility with legacy programs but may result
        \\  in incorrect grapheme width for certain graphemes such as skin-tone
        \\  emoji, non-English characters, etc.
        \\
        \\  This is called "legacy" and not something more specific because the
        \\  behavior is undefined and we want to retain the ability to modify it.
        \\  For example, we may or may not use libc `wcswidth` now or in the future.
        \\
        \\* `unicode` - Use the Unicode standard to determine grapheme width.
        \\
        \\If a running program explicitly enables terminal mode 2027, then `unicode`
        \\width will be forced regardless of this configuration. When mode 2027 is
        \\reset, this configuration will be used again.
        \\
        \\This configuration can be changed at runtime but will not affect existing
        \\terminals. Only new terminals will use the new configuration.
        ,
        .full_zh =
        \\计算字素簇单元格宽度的方法。默认值为 `unicode`，按 Unicode 标准确定字素宽度。这样得到的宽度是对的，但对一些仍用 `wcswidth` 等旧方法的程序（如 shell），可能造成光标错位。
        \\
        \\有效值：
        \\
        \\* `legacy` - 用旧方法（如 wcswidth）确定字素宽度。这能最大程度兼容旧程序，但对某些字素（如带肤色的 emoji、非英文字符等）可能得到错误的宽度。
        \\
        \\  它叫 “legacy” 而不是更具体的名字，是因为这种行为没有明确定义，我们想保留修改它的余地。例如，我们现在或将来可能用、也可能不用 libc 的 `wcswidth`。
        \\
        \\* `unicode` - 按 Unicode 标准确定字素宽度。
        \\
        \\如果正在运行的程序明确启用了终端模式 2027，则无论这项配置如何，都会强制使用 `unicode` 宽度。模式 2027 被重置后，会再次使用这项配置。
        \\
        \\这项配置可以在运行时更改，但不会影响现有的终端，只有新的终端会使用新配置。
        ,
    },
    .{
        .key = .@"freetype-load-flags",
        .en = "FreeType load flags to enable. The format of this is a list of flags to enable separated by commas. If you prefix a flag with `no-` then it is disabled. If you omit a flag, its default value is used, so you must explicitly disable flags you don't want. You can also use `true` or `false` to turn all flags on or off.",
        .zh = "要启用的 FreeType 加载标志。格式是用逗号分隔的、要启用的标志列表。标志前加 `no-` 表示禁用。省略的标志使用其默认值，所以不想要的标志必须明确禁用。也可以用 `true` 或 `false` 一次打开或关闭所有标志。",
        .full_en =
        \\FreeType load flags to enable. The format of this is a list of flags to
        \\enable separated by commas. If you prefix a flag with `no-` then it is
        \\disabled. If you omit a flag, its default value is used, so you must
        \\explicitly disable flags you don't want. You can also use `true` or `false`
        \\to turn all flags on or off.
        \\
        \\This configuration only applies to Ghostty builds that use FreeType.
        \\This is usually the case only for Linux builds. macOS uses CoreText
        \\and does not have an equivalent configuration.
        \\
        \\Available flags:
        \\
        \\  * `hinting` - Enable or disable hinting. Enabled by default.
        \\
        \\  * `force-autohint` - Always use the freetype auto-hinter instead of
        \\    the font's native hinter. Disabled by default.
        \\
        \\  * `monochrome` - Instructs renderer to use 1-bit monochrome rendering.
        \\    This will disable anti-aliasing, and probably not look very good unless
        \\    you're using a pixel font. Disabled by default.
        \\
        \\  * `autohint` - Enable the freetype auto-hinter. Enabled by default.
        \\
        \\  * `light` - Use a light hinting style, better preserving glyph shapes.
        \\    This is the most common setting in GTK apps and therefore also Ghostty's
        \\    default. This has no effect if `monochrome` is enabled. Enabled by
        \\    default.
        \\
        \\Example: `hinting`, `no-hinting`, `force-autohint`, `no-force-autohint`
        ,
        .full_zh =
        \\要启用的 FreeType 加载标志。格式是用逗号分隔的、要启用的标志列表。标志前加 `no-` 表示禁用。省略的标志使用其默认值，所以不想要的标志必须明确禁用。也可以用 `true` 或 `false` 一次打开或关闭所有标志。
        \\
        \\这项配置只作用于使用 FreeType 的 Ghostty 构建，通常只有 Linux 构建是这样。macOS 使用 CoreText，没有对应的配置。
        \\
        \\可用的标志：
        \\
        \\  * `hinting` - 启用或禁用 hinting（字形微调）。默认启用。
        \\
        \\  * `force-autohint` - 始终使用 freetype 的自动微调器，而不是字体自带的微调器。默认禁用。
        \\
        \\  * `monochrome` - 让渲染器使用 1 位单色渲染。这会禁用抗锯齿，除非你用的是像素字体，否则大概不会好看。默认禁用。
        \\
        \\  * `autohint` - 启用 freetype 自动微调器。默认启用。
        \\
        \\  * `light` - 使用轻度微调风格，更好地保留字形形状。这是 GTK 应用里最常见的设置，因此也是 Ghostty 的默认值。启用 `monochrome` 时无效。默认启用。
        \\
        \\示例：`hinting`、`no-hinting`、`force-autohint`、`no-force-autohint`
        ,
    },
    .{
        .key = .theme,
        .en = "A theme to use. This can be a built-in theme name, a custom theme name, or an absolute path to a custom theme file. Ghostty also supports specifying a different theme to use for light and dark mode. Each option is documented below.",
        .zh = "使用的主题。可以是内置主题名、自定义主题名，或自定义主题文件的绝对路径。Ghostty 也支持为浅色和深色模式分别指定主题。每种写法在下文都有说明。",
        .full_en =
        \\A theme to use. This can be a built-in theme name, a custom theme
        \\name, or an absolute path to a custom theme file. Ghostty also supports
        \\specifying a different theme to use for light and dark mode. Each
        \\option is documented below.
        \\
        \\If the theme is an absolute pathname, Ghostty will attempt to load that
        \\file as a theme. If that file does not exist or is inaccessible, an error
        \\will be logged and no other directories will be searched.
        \\
        \\If the theme is not an absolute pathname, two different directories will be
        \\searched for a file name that matches the theme. This is case sensitive on
        \\systems with case-sensitive filesystems. It is an error for a theme name to
        \\include path separators unless it is an absolute pathname.
        \\
        \\The first directory is the `themes` subdirectory of your Ghostty
        \\configuration directory. This is `$XDG_CONFIG_HOME/ghostty/themes` or
        \\`~/.config/ghostty/themes`.
        \\
        \\The second directory is the `themes` subdirectory of the Ghostty resources
        \\directory. Ghostty ships with a multitude of themes that will be installed
        \\into this directory. On macOS, this list is in the
        \\`Ghostty.app/Contents/Resources/ghostty/themes` directory. On Linux, this
        \\list is in the `share/ghostty/themes` directory (wherever you installed the
        \\Ghostty "share" directory.
        \\
        \\To see a list of available themes, run `ghostty +list-themes`.
        \\
        \\A theme file is simply another Ghostty configuration file. They share
        \\the same syntax and same configuration options. A theme can set any valid
        \\configuration option so please do not use a theme file from an untrusted
        \\source. The built-in themes are audited to only set safe configuration
        \\options.
        \\
        \\Some options cannot be set within theme files. The reason these are not
        \\supported should be self-evident. A theme file cannot set `theme` or
        \\`config-file`. At the time of writing this, Ghostty will not show any
        \\warnings or errors if you set these options in a theme file but they will
        \\be silently ignored.
        \\
        \\Any additional colors specified via background, foreground, palette, etc.
        \\will override the colors specified in the theme.
        \\
        \\To specify a different theme for light and dark mode, use the following
        \\syntax: `light:theme-name,dark:theme-name`. For example:
        \\`light:Rose Pine Dawn,dark:Rose Pine`. Whitespace around all values are
        \\trimmed and order of light and dark does not matter. Both light and dark
        \\must be specified in this form. In this form, the theme used will be
        \\based on the current desktop environment theme.
        \\
        \\There are some known bugs with light/dark mode theming. These will
        \\be fixed in a future update:
        \\
        \\  - macOS: titlebar tabs style is not updated when switching themes.
        ,
        .full_zh =
        \\使用的主题。可以是内置主题名、自定义主题名，或自定义主题文件的绝对路径。Ghostty 也支持为浅色和深色模式分别指定主题。每种写法在下文都有说明。
        \\
        \\如果主题是绝对路径，Ghostty 会尝试把那个文件作为主题加载。如果文件不存在或无法访问，会记录一条错误，且不会再搜索其他目录。
        \\
        \\如果主题不是绝对路径，会在两个目录里查找与主题同名的文件。在区分大小写的文件系统上，匹配区分大小写。主题名里含有路径分隔符是错误的，除非它是绝对路径。
        \\
        \\第一个目录是 Ghostty 配置目录下的 `themes` 子目录，即 `$XDG_CONFIG_HOME/ghostty/themes` 或 `~/.config/ghostty/themes`。
        \\
        \\第二个目录是 Ghostty 资源目录下的 `themes` 子目录。Ghostty 自带大量主题，会安装到这个目录里。在 macOS 上，这个列表在 `Ghostty.app/Contents/Resources/ghostty/themes` 目录里。在 Linux 上，这个列表在 `share/ghostty/themes` 目录里（Ghostty “share” 目录安装在哪里就在哪里）。
        \\
        \\要查看可用主题的列表，运行 `ghostty +list-themes`。
        \\
        \\主题文件其实就是另一个 Ghostty 配置文件，语法和配置项都相同。主题可以设置任何有效的配置项，所以请不要使用来路不明的主题文件。内置主题经过审核，只设置安全的配置项。
        \\
        \\有些配置项不能在主题文件里设置，原因不言自明：主题文件不能设置 `theme` 或 `config-file`。写这段说明时，如果你在主题文件里设置了这些项，Ghostty 不会显示任何警告或错误，但会悄悄忽略它们。
        \\
        \\通过 background、foreground、palette 等另外指定的颜色，会覆盖主题里指定的颜色。
        \\
        \\要为浅色和深色模式分别指定主题，用这样的语法：`light:theme-name,dark:theme-name`。例如：`light:Rose Pine Dawn,dark:Rose Pine`。所有值两侧的空白都会被去掉，light 和 dark 的先后顺序无关紧要。这种写法必须同时指定 light 和 dark。使用这种写法时，所用的主题取决于当前桌面环境的主题。
        \\
        \\浅色/深色模式的主题目前有一些已知的错误，将在以后的更新里修复：
        \\
        \\  - macOS：切换主题时，标签页式标题栏的样式不会更新。
        ,
    },
    .{ .key = .background, .en = "Background color for the window. Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.", .zh = "窗口的背景色。可写成十六进制（`#RRGGBB` 或 `RRGGBB`），或 X11 颜色名。" },
    .{ .key = .foreground, .en = "Foreground color for the window. Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.", .zh = "窗口的前景色。可写成十六进制（`#RRGGBB` 或 `RRGGBB`），或 X11 颜色名。" },
    .{
        .key = .@"background-image",
        .en = "Background image for the terminal.",
        .zh = "终端的背景图片。",
        .full_en =
        \\Background image for the terminal.
        \\
        \\This should be a path to a PNG or JPEG file, other image formats are
        \\not yet supported.
        \\
        \\The background image is currently per-terminal, not per-window. If
        \\you are a heavy split user, the background image will be repeated across
        \\splits. A future improvement to Ghostty will address this.
        \\
        \\WARNING: Background images are currently duplicated in VRAM per-terminal.
        \\For sufficiently large images, this could lead to a large increase in
        \\memory usage (specifically VRAM usage). A future Ghostty improvement
        \\will resolve this by sharing image textures across terminals.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\终端的背景图片。
        \\
        \\应当是 PNG 或 JPEG 文件的路径，暂不支持其他图片格式。
        \\
        \\背景图片目前是每个终端各一张，而不是每个窗口一张。如果你大量使用分屏，背景图片会在各个分屏里重复。Ghostty 以后会改进这一点。
        \\
        \\警告：背景图片目前在每个终端的显存（VRAM）里各存一份。图片足够大时，可能让内存（具体是显存）用量大幅增加。Ghostty 以后会改进，让各终端共享图片纹理，从而解决这个问题。
        \\
        \\自 1.2.0 起可用
        ,
    },
    .{
        .key = .@"background-image-opacity",
        .en = "Background image opacity.",
        .zh = "背景图片的不透明度。",
        .full_en =
        \\Background image opacity.
        \\
        \\This is relative to the value of `background-opacity`.
        \\
        \\A value of `1.0` (the default) will result in the background image being
        \\placed on top of the general background color, and then the combined result
        \\will be adjusted to the opacity specified by `background-opacity`.
        \\
        \\A value less than `1.0` will result in the background image being mixed
        \\with the general background color before the combined result is adjusted
        \\to the configured `background-opacity`.
        \\
        \\A value greater than `1.0` will result in the background image having a
        \\higher opacity than the general background color. For instance, if the
        \\configured `background-opacity` is `0.5` and `background-image-opacity`
        \\is set to `1.5`, then the final opacity of the background image will be
        \\`0.5 * 1.5 = 0.75`.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\背景图片的不透明度。
        \\
        \\它是相对于 `background-opacity` 的值而言的。
        \\
        \\值为 `1.0`（默认值）时，背景图片放在一般背景色之上，再把合成的结果调整到 `background-opacity` 指定的不透明度。
        \\
        \\值小于 `1.0` 时，背景图片先与一般背景色混合，再把合成的结果调整到所配置的 `background-opacity`。
        \\
        \\值大于 `1.0` 时，背景图片的不透明度会比一般背景色更高。例如，所配置的 `background-opacity` 是 `0.5`、`background-image-opacity` 设为 `1.5` 时，背景图片最终的不透明度是 `0.5 * 1.5 = 0.75`。
        \\
        \\自 1.2.0 起可用
        ,
    },
    .{
        .key = .@"background-image-position",
        .en = "Background image position.",
        .zh = "背景图片的位置。",
        .full_en =
        \\Background image position.
        \\
        \\Valid values are:
        \\  * `top-left`
        \\  * `top-center`
        \\  * `top-right`
        \\  * `center-left`
        \\  * `center`
        \\  * `center-right`
        \\  * `bottom-left`
        \\  * `bottom-center`
        \\  * `bottom-right`
        \\
        \\The default value is `center`.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\背景图片的位置。
        \\
        \\有效值：
        \\  * `top-left`
        \\  * `top-center`
        \\  * `top-right`
        \\  * `center-left`
        \\  * `center`
        \\  * `center-right`
        \\  * `bottom-left`
        \\  * `bottom-center`
        \\  * `bottom-right`
        \\
        \\默认值是 `center`。
        \\
        \\自 1.2.0 起可用
        ,
    },
    .{
        .key = .@"background-image-fit",
        .en = "Background image fit.",
        .zh = "背景图片的适应方式。",
        .full_en =
        \\Background image fit.
        \\
        \\Valid values are:
        \\
        \\ * `contain`
        \\
        \\   Preserving the aspect ratio, scale the background image to the largest
        \\   size that can still be contained within the terminal, so that the whole
        \\   image is visible.
        \\
        \\ * `cover`
        \\
        \\   Preserving the aspect ratio, scale the background image to the smallest
        \\   size that can completely cover the terminal. This may result in one or
        \\   more edges of the image being clipped by the edge of the terminal.
        \\
        \\ * `stretch`
        \\
        \\   Stretch the background image to the full size of the terminal, without
        \\   preserving the aspect ratio.
        \\
        \\ * `none`
        \\
        \\   Don't scale the background image.
        \\
        \\The default value is `contain`.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\背景图片的适应方式。
        \\
        \\有效值：
        \\
        \\ * `contain`
        \\
        \\   保持宽高比，把背景图片缩放到终端仍能容纳的最大尺寸，这样整张图片都可见。
        \\
        \\ * `cover`
        \\
        \\   保持宽高比，把背景图片缩放到能完全盖住终端的最小尺寸。这可能让图片的一条或多条边被终端边缘裁掉。
        \\
        \\ * `stretch`
        \\
        \\   把背景图片拉伸到终端的完整大小，不保持宽高比。
        \\
        \\ * `none`
        \\
        \\   不缩放背景图片。
        \\
        \\默认值是 `contain`。
        \\
        \\自 1.2.0 起可用
        ,
    },
    .{
        .key = .@"background-image-repeat",
        .en = "Whether to repeat the background image or not.",
        .zh = "背景图片是否重复平铺。",
        .full_en =
        \\Whether to repeat the background image or not.
        \\
        \\If this is set to true, the background image will be repeated if there
        \\would otherwise be blank space around it because it doesn't completely
        \\fill the terminal area.
        \\
        \\The default value is `false`.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\背景图片是否重复平铺。
        \\
        \\设为 true 时，如果背景图片没有完全铺满终端区域，周围会出现空白，这时背景图片会重复铺开。
        \\
        \\默认值是 `false`。
        \\
        \\自 1.2.0 起可用
        ,
    },
    .{ .key = .@"selection-foreground", .en = "The foreground and background color for selection. If this is not set, then the selection color is just the inverted window background and foreground (note: not to be confused with the cell bg/fg). Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color. Since version 1.2.0, this can also be set to `cell-foreground` to match the cell foreground color, or `cell-background` to match the cell background color.", .zh = "选区的前景色和背景色。如果不设置，选区颜色就是窗口背景色和前景色的反色（注意：与单元格的背景/前景色无关）。可写成十六进制（`#RRGGBB` 或 `RRGGBB`），或 X11 颜色名。自 1.2.0 版起，也可设为 `cell-foreground`（与单元格前景色一致）或 `cell-background`（与单元格背景色一致）。" },
    .{
        .key = .@"selection-clear-on-typing",
        .en = "Whether to clear selected text when typing. This defaults to `true`. This is typical behavior for most terminal emulators as well as text input fields. If you set this to `false`, then the selected text will not be cleared when typing.",
        .zh = "输入时是否清除已选中的文本。默认为 `true`，这是大多数终端模拟器和文本输入框的常见行为。设为 `false` 后，输入时不会清除选中的文本。",
        .full_en =
        \\Whether to clear selected text when typing. This defaults to `true`.
        \\This is typical behavior for most terminal emulators as well as
        \\text input fields. If you set this to `false`, then the selected text
        \\will not be cleared when typing.
        \\
        \\"Typing" is specifically defined as any non-modifier (shift, control,
        \\alt, etc.) keypress that produces data to be sent to the application
        \\running within the terminal (e.g. the shell). Additionally, selection
        \\is cleared when any preedit or composition state is started (e.g.
        \\when typing languages such as Japanese).
        \\
        \\If this is `false`, then the selection can still be manually
        \\cleared by clicking once or by pressing `escape`.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\输入时是否清除已选中的文本。默认为 `true`，这是大多数终端模拟器和文本输入框的常见行为。设为 `false` 后，输入时不会清除选中的文本。
        \\
        \\“输入”具体指任何非修饰键（shift、control、alt 等）的按键，只要它产生了要发送给终端里运行的应用（如 shell）的数据。另外，开始任何预编辑或组字状态时（例如输入日语等语言时），选区也会被清除。
        \\
        \\如果设为 `false`，仍然可以手动清除选区：单击一次，或按 `escape`。
        \\
        \\自 1.2.0 起可用
        ,
    },
    .{
        .key = .@"selection-clear-on-copy",
        .en = "Whether to clear selected text after copying. This defaults to `false` everywhere except Windows, where it defaults to `true`.",
        .zh = "复制后是否清除选区。默认为 `false`，只有 Windows 上默认为 `true`。",
        .full_en =
        \\Whether to clear selected text after copying. This defaults to `false`
        \\everywhere except Windows, where it defaults to `true`.
        \\
        \\When set to `true`, the selection will be automatically cleared after
        \\any copy operation that invokes the `copy_to_clipboard` keyboard binding.
        \\Importantly, this will not clear the selection if the copy operation
        \\was invoked via `copy-on-select`.
        \\
        \\When set to `false`, the selection remains visible after copying, allowing
        \\to see what was copied and potentially perform additional operations
        \\on the same selection.
        \\
        \\**The Windows default is a deliberate divergence from upstream, and it is
        \\one half of a pair.** The other half is the `ctrl+c` binding in
        \\`Keybinds.init`; read that comment first, because this value on its own
        \\looks like a taste preference and is not one. On Windows `ctrl+c` copies
        \\when there is a selection and interrupts when there is not, which is what
        \\Windows Terminal does and what people arrive expecting. That only works if
        \\copying also *ends* the selection: leave it standing and the next `ctrl+c`
        \\copies the same text again instead of interrupting, so the key silently
        \\stops being an interrupt key until the user thinks to click somewhere.
        \\With `ctrl+shift+c` -- the binding every other platform uses -- there is no
        \\such trap, because nothing else is competing for the chord.
        \\
        \\Diverging is not the problem; diverging quietly is. Set it explicitly in
        \\your config to get the old behaviour back on Windows.
        ,
        .full_zh =
        \\复制后是否清除选区。默认为 `false`，只有 Windows 上默认为 `true`。
        \\
        \\设为 `true` 时，任何调用 `copy_to_clipboard` 键绑定的复制操作之后，选区会自动清除。要注意，如果复制是通过 `copy-on-select` 触发的，则不会清除选区。
        \\
        \\设为 `false` 时，复制后选区仍然可见，这样可以看到复制了什么，还可以对同一选区继续做其他操作。
        \\
        \\**Windows 上的默认值是有意与上游不同的，而且是成对的两半之一。** 另一半是 `Keybinds.init` 里的 `ctrl+c` 绑定；请先读那里的注释，因为单看这个值，像是个人口味的偏好，其实不是。在 Windows 上，`ctrl+c` 有选区时复制、没有选区时中断，这是 Windows Terminal 的做法，也是大家来了就期待的行为。这只有在复制同时*结束*选区时才行得通：选区还留着的话，下一次 `ctrl+c` 会再次复制同样的文字而不是中断，于是这个键悄悄不再是中断键，直到用户想到点一下别处。换成 `ctrl+shift+c`（其他所有平台用的绑定）就没有这个陷阱，因为没有别的东西跟这个组合键争用。
        \\
        \\问题不在于与上游不同，而在于悄悄地不同。如果想在 Windows 上回到原来的行为，请在你的配置里明确设置它。
        ,
    },
    .{
        .key = .@"selection-word-chars",
        .en = "Characters that mark word boundaries during text selection operations such as double-clicking. When selecting a word, the selection will stop at any of these characters.",
        .zh = "在双击等选区操作中，标记单词边界的字符。选中一个单词时，选区会在遇到这些字符时停下。",
        .full_en =
        \\Characters that mark word boundaries during text selection operations such
        \\as double-clicking. When selecting a word, the selection will stop at any
        \\of these characters.
        \\
        \\This is similar to the `WORDCHARS` environment variable in zsh, except this
        \\specifies the boundary characters rather than the word characters. The
        \\default includes common delimiters and punctuation that typically separate
        \\words in code and prose.
        \\
        \\Each character in this string becomes a word boundary. Multi-byte UTF-8
        \\characters are supported, but only single codepoints can be specified.
        \\Multi-codepoint sequences (e.g. emoji) are not supported.
        \\
        \\The null character (U+0000) is always treated as a boundary and does not
        \\need to be included in this configuration.
        \\
        \\Default: ``\t '"│`|:;,()[]{}<>$``
        \\
        \\To add or remove specific characters, you can set this to a custom value.
        \\For example, to treat semicolons as part of words:
        \\
        \\    selection-word-chars = "\t '\"│`|:,()[]{}<>$"
        \\
        \\Available since: 1.3.0
        ,
        .full_zh =
        \\在双击等选区操作中，标记单词边界的字符。选中一个单词时，选区会在遇到这些字符时停下。
        \\
        \\这与 zsh 的 `WORDCHARS` 环境变量类似，只是这里指定的是边界字符，而不是单词字符。默认值包含常见的分隔符和标点，它们通常用来分隔代码和文章里的单词。
        \\
        \\这个字符串里的每个字符都成为一个单词边界。支持多字节的 UTF-8 字符，但只能指定单个码位，不支持多码位序列（如 emoji）。
        \\
        \\空字符（U+0000）始终被当作边界，不需要写进这项配置。
        \\
        \\默认值：``\t '"│`|:;,()[]{}<>$``
        \\
        \\要增加或删除某些字符，可以把它设成自定义的值。例如，要把分号当作单词的一部分：
        \\
        \\    selection-word-chars = "\t '\"│`|:,()[]{}<>$"
        \\
        \\自 1.3.0 起可用
        ,
    },
    .{
        .key = .@"minimum-contrast",
        .en = "The minimum contrast ratio between the foreground and background colors. The contrast ratio is a value between 1 and 21. A value of 1 allows for no contrast (e.g. black on black). This value is the contrast ratio as defined by the [WCAG 2.0 specification](https://www.w3.org/TR/WCAG20/).",
        .zh = "前景色和背景色之间的最小对比度。对比度是 1 到 21 之间的值，1 表示没有对比（例如黑底黑字）。该值按 [WCAG 2.0 规范](https://www.w3.org/TR/WCAG20/) 定义的对比度计算。",
        .full_en =
        \\The minimum contrast ratio between the foreground and background colors.
        \\The contrast ratio is a value between 1 and 21. A value of 1 allows for no
        \\contrast (e.g. black on black). This value is the contrast ratio as defined
        \\by the [WCAG 2.0 specification](https://www.w3.org/TR/WCAG20/).
        \\
        \\If you want to avoid invisible text (same color as background), a value of
        \\1.1 is a good value. If you want to avoid text that is difficult to read, a
        \\value of 3 or higher is a good value. The higher the value, the more likely
        \\that text will become black or white.
        \\
        \\This value does not apply to Emoji or images.
        ,
        .full_zh =
        \\前景色和背景色之间的最小对比度。对比度是 1 到 21 之间的值，1 表示没有对比（例如黑底黑字）。该值按 [WCAG 2.0 规范](https://www.w3.org/TR/WCAG20/) 定义的对比度计算。
        \\
        \\如果想避免文字看不见（颜色与背景相同），1.1 是个不错的值。如果想避免难以阅读的文字，3 或更高是个不错的值。值越高，文字越有可能变成黑色或白色。
        \\
        \\这个值不适用于 Emoji 或图像。
        ,
    },
    .{
        .key = .palette,
        .en = "Color palette for the 256 color form that many terminal applications use. The syntax of this configuration is `N=COLOR` where `N` is 0 to 255 (for the 256 colors in the terminal color table) and `COLOR` is a typical RGB color code such as `#AABBCC` or `AABBCC`, or a named X11 color. For example, `palette = 5=#BB78D9` will set the 'purple' color.",
        .zh = "许多终端程序使用的 256 色调色板。语法是 `N=COLOR`：`N` 为 0 到 255（对应终端色表里的 256 种颜色），`COLOR` 为常见的 RGB 颜色码，如 `#AABBCC` 或 `AABBCC`，或 X11 颜色名。例如 `palette = 5=#BB78D9` 会设置“紫色”。",
        .full_en =
        \\Color palette for the 256 color form that many terminal applications use.
        \\The syntax of this configuration is `N=COLOR` where `N` is 0 to 255 (for
        \\the 256 colors in the terminal color table) and `COLOR` is a typical RGB
        \\color code such as `#AABBCC` or `AABBCC`, or a named X11 color. For example,
        \\`palette = 5=#BB78D9` will set the 'purple' color.
        \\
        \\The palette index can be in decimal, binary, octal, or hexadecimal.
        \\Decimal is assumed unless a prefix is used: `0b` for binary, `0o` for octal,
        \\and `0x` for hexadecimal.
        \\
        \\For definitions on the color indices and what they canonically map to,
        \\[see this cheat sheet](https://www.ditig.com/256-colors-cheat-sheet).
        \\
        \\For most themes, you only need to set the first 16 colors (0–15) since the
        \\rest of the palette (16–255) will be automatically generated by
        \\default (see `palette-generate` for more details).
        ,
        .full_zh =
        \\许多终端程序使用的 256 色调色板。语法是 `N=COLOR`：`N` 为 0 到 255（对应终端色表里的 256 种颜色），`COLOR` 为常见的 RGB 颜色码，如 `#AABBCC` 或 `AABBCC`，或 X11 颜色名。例如 `palette = 5=#BB78D9` 会设置“紫色”。
        \\
        \\调色板索引可以用十进制、二进制、八进制或十六进制。不加前缀时按十进制处理；二进制用 `0b` 前缀，八进制用 `0o`，十六进制用 `0x`。
        \\
        \\关于各颜色索引的定义及其通常对应的颜色，[见这份速查表](https://www.ditig.com/256-colors-cheat-sheet)。
        \\
        \\对大多数主题，只需要设置前 16 种颜色（0–15），因为调色板的其余部分（16–255）默认会自动生成（详见 `palette-generate`）。
        ,
    },
    .{
        .key = .@"palette-generate",
        .en = "Whether to automatically generate the extended 256 color palette (indices 16–255) from the base 16 ANSI colors.",
        .zh = "是否根据基础 16 种 ANSI 颜色自动生成扩展的 256 色调色板（索引 16–255）。",
        .full_en =
        \\Whether to automatically generate the extended 256 color palette
        \\(indices 16–255) from the base 16 ANSI colors.
        \\
        \\This lets theme authors specify only the base 16 colors and have the
        \\rest of the palette be automatically generated in a consistent and
        \\aesthetic way.
        \\
        \\When enabled, the 6×6×6 color cube and 24-step grayscale ramp are
        \\derived from interpolations of the base palette, giving a more cohesive
        \\look. Colors that have been explicitly set via `palette` are never
        \\overwritten.
        \\
        \\The default value is false (disabled), because many legacy programs
        \\using the 256-color palette hardcode assumptions about what these
        \\colors are (mostly assuming the xterm 256 color palette). However, this
        \\is still a very useful tool for theme authors and users who want
        \\to customize their palette without having to specify all 256 colors.
        \\
        \\For more information on how the generation works, see here:
        \\https://gist.github.com/jake-stewart/0a8ea46159a7da2c808e5be2177e1783
        \\
        \\Available since: 1.3.0
        ,
        .full_zh =
        \\是否根据基础 16 种 ANSI 颜色自动生成扩展的 256 色调色板（索引 16–255）。
        \\
        \\这样主题作者只需要指定基础的 16 种颜色，其余的调色板会以一致而美观的方式自动生成。
        \\
        \\启用后，6×6×6 的色立方和 24 级灰阶由基础调色板插值得出，整体看起来更协调。已通过 `palette` 明确设置的颜色永远不会被覆盖。
        \\
        \\默认值是 false（禁用），因为许多使用 256 色调色板的旧程序把这些颜色是什么写死了（多半假定是 xterm 的 256 色调色板）。不过，对想自定义调色板、又不想逐一指定全部 256 种颜色的主题作者和用户，这仍是个很有用的工具。
        \\
        \\生成方式的详情见这里：
        \\https://gist.github.com/jake-stewart/0a8ea46159a7da2c808e5be2177e1783
        \\
        \\自 1.3.0 起可用
        ,
    },
    .{
        .key = .@"palette-harmonious",
        .en = "Invert the palette colors generated when `palette-generate` is enabled, so that the colors go in reverse order. This allows palette-based applications to work well in both light and dark mode since the palettes are always relatively good colors.",
        .zh = "启用 `palette-generate` 时，把生成的调色板颜色反转，使颜色顺序倒过来。这样依赖调色板的程序在浅色和深色模式下都好看，因为调色板总是相对合适的颜色。",
        .full_en =
        \\Invert the palette colors generated when `palette-generate` is enabled,
        \\so that the colors go in reverse order. This allows palette-based
        \\applications to work well in both light and dark mode since the
        \\palettes are always relatively good colors.
        \\
        \\This defaults to off because some legacy terminal applications
        \\hardcode the assumption that palette indices 16–231 are ordered from
        \\darkest to lightest, so enabling this would make them unreadable.
        \\This is not a generally good assumption and we encourage modern
        \\terminal applications to use the indices in a more semantic way.
        \\
        \\This has no effect if `palette-generate` is disabled.
        \\
        \\For more information see `palette-generate`.
        \\
        \\Available since: 1.3.0
        ,
        .full_zh =
        \\启用 `palette-generate` 时，把生成的调色板颜色反转，使颜色顺序倒过来。这样依赖调色板的程序在浅色和深色模式下都好看，因为调色板总是相对合适的颜色。
        \\
        \\默认关闭，因为一些旧的终端应用把“调色板索引 16–231 按从最暗到最亮排列”写成了固定假设，启用后它们会变得无法阅读。这并不是一个普遍成立的好假设，我们鼓励现代终端应用以更有语义的方式使用这些索引。
        \\
        \\如果 `palette-generate` 被禁用，这项配置无效。
        \\
        \\更多信息见 `palette-generate`。
        \\
        \\自 1.3.0 起可用
        ,
    },
    .{
        .key = .@"cursor-color",
        .en = "The color of the cursor. If this is not set, a default will be chosen.",
        .zh = "光标的颜色。不设置时会选用默认值。",
        .full_en =
        \\The color of the cursor. If this is not set, a default will be chosen.
        \\
        \\Direct colors can be specified as either hex (`#RRGGBB` or `RRGGBB`)
        \\or a named X11 color.
        \\
        \\Additionally, special values can be used to set the color to match
        \\other colors at runtime:
        \\
        \\  * `cell-foreground` - Match the cell foreground color.
        \\    (Available since: 1.2.0)
        \\
        \\  * `cell-background` - Match the cell background color.
        \\    (Available since: 1.2.0)
        ,
        .full_zh =
        \\光标的颜色。不设置时会选用默认值。
        \\
        \\可以直接指定颜色，写成十六进制（`#RRGGBB` 或 `RRGGBB`）或 X11 颜色名。
        \\
        \\另外，还可以用一些特殊值，让颜色在运行时与其他颜色保持一致：
        \\
        \\  * `cell-foreground` - 与单元格前景色一致。
        \\    （自 1.2.0 起可用）
        \\
        \\  * `cell-background` - 与单元格背景色一致。
        \\    （自 1.2.0 起可用）
        ,
    },
    .{ .key = .@"cursor-opacity", .en = "The opacity level (opposite of transparency) of the cursor. A value of 1 is fully opaque and a value of 0 is fully transparent. A value less than 0 or greater than 1 will be clamped to the nearest valid value. Note that a sufficiently small value such as 0.3 may be effectively invisible and may make it difficult to find the cursor.", .zh = "光标的不透明度（透明度的反面）。1 为完全不透明，0 为完全透明。小于 0 或大于 1 的值会被限制到最近的有效值。注意，像 0.3 这样足够小的值可能几乎看不见，让光标难以找到。" },
    .{
        .key = .@"cursor-style",
        .en = "The style of the cursor. This sets the default style. A running program can still request an explicit cursor style using escape sequences (such as `CSI q`). Shell configurations will often request specific cursor styles.",
        .zh = "光标的样式。这里设置的是默认样式；运行中的程序仍可用转义序列（如 `CSI q`）明确请求某种光标样式。Shell 的配置经常会请求特定的光标样式。",
        .full_en =
        \\The style of the cursor. This sets the default style. A running program can
        \\still request an explicit cursor style using escape sequences (such as `CSI
        \\q`). Shell configurations will often request specific cursor styles.
        \\
        \\Note that shell integration will automatically set the cursor to a bar at
        \\a prompt, regardless of this configuration. You can disable that behavior
        \\by specifying `shell-integration-features = no-cursor` or disabling shell
        \\integration entirely.
        \\
        \\Valid values are:
        \\
        \\  * `block`
        \\  * `bar`
        \\  * `underline`
        \\  * `block_hollow`
        ,
        .full_zh =
        \\光标的样式。这里设置的是默认样式；运行中的程序仍可用转义序列（如 `CSI q`）明确请求某种光标样式。Shell 的配置经常会请求特定的光标样式。
        \\
        \\注意，无论这项配置如何，shell 集成都会在提示符处自动把光标设成竖线。可以通过指定 `shell-integration-features = no-cursor`，或完全禁用 shell 集成，来关闭这一行为。
        \\
        \\有效值：
        \\
        \\  * `block`
        \\  * `bar`
        \\  * `underline`
        \\  * `block_hollow`
        ,
    },
    .{ .key = .@"cursor-style-blink", .en = "Sets the default blinking state of the cursor. This is just the default state; running programs may override the cursor style using `DECSCUSR` (`CSI q`).", .zh = "光标默认是否闪烁。这只是默认状态；运行中的程序可以用 `DECSCUSR`（`CSI q`）改变光标样式。" },
    .{ .key = .@"cursor-text", .en = "The color of the text under the cursor. If this is not set, a default will be chosen. Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color. Since version 1.2.0, this can also be set to `cell-foreground` to match the cell foreground color, or `cell-background` to match the cell background color.", .zh = "光标下文字的颜色。不设置时会选用默认值。可写成十六进制（`#RRGGBB` 或 `RRGGBB`），或 X11 颜色名。自 1.2.0 版起，也可设为 `cell-foreground`（与单元格前景色一致）或 `cell-background`（与单元格背景色一致）。" },
    .{ .key = .@"cursor-click-to-move", .en = "Enables the ability to move the cursor at prompts by clicking on a location in the prompt text.", .zh = "允许在提示符处点击提示符文本中的某个位置来移动光标。" },
    .{ .key = .@"mouse-hide-while-typing", .en = "Hide the mouse immediately when typing. The mouse becomes visible again when the mouse is used (button, movement, etc.). Platform-specific behavior may dictate other scenarios where the mouse is shown. For example on macOS, the mouse is shown again when a new window, tab, or split is created.", .zh = "输入时立即隐藏鼠标。再次使用鼠标（按键、移动等）时鼠标重新显示。平台特有的行为可能规定在其他情形下也显示鼠标。例如在 macOS 上，新建窗口、标签页或分屏时会重新显示鼠标。" },
    .{ .key = .@"scroll-to-bottom", .en = "When to scroll the surface to the bottom. The format of this is a list of options to enable separated by commas. If you prefix an option with `no-` then it is disabled. If you omit an option, its default value is used.", .zh = "何时把终端滚动到底部。格式是用逗号分隔的、要启用的选项列表。选项前加 `no-` 表示禁用。省略的选项使用其默认值。" },
    .{ .key = .@"mouse-shift-capture", .en = "Determines whether running programs can detect the shift key pressed with a mouse click. Typically, the shift key is used to extend mouse selection.", .zh = "决定运行中的程序能否检测到鼠标点击时按下了 Shift 键。通常 Shift 键用来扩展鼠标选区。" },
    .{ .key = .@"mouse-reporting", .en = "Enable or disable mouse reporting. When set to `false`, mouse events will not be reported to terminal applications even if they request it. This allows you to always use the mouse for selection and other terminal UI interactions without applications capturing mouse input.", .zh = "启用或禁用鼠标事件上报。设为 `false` 时，即使终端程序请求，也不会向它们上报鼠标事件。这样你可以始终用鼠标做选择和其他终端界面操作，而不被程序抢走鼠标输入。" },
    .{ .key = .@"mouse-scroll-multiplier", .en = "Multiplier for scrolling distance with the mouse wheel.", .zh = "鼠标滚轮滚动距离的倍数。" },
    .{ .key = .@"background-opacity", .en = "The opacity level (opposite of transparency) of the background. A value of 1 is fully opaque and a value of 0 is fully transparent. A value less than 0 or greater than 1 will be clamped to the nearest valid value.", .zh = "背景的不透明度（透明度的反面）。1 为完全不透明，0 为完全透明。小于 0 或大于 1 的值会被限制到最近的有效值。" },
    .{ .key = .@"background-opacity-cells", .en = "Applies background opacity to cells with an explicit background color set.", .zh = "把背景不透明度也应用到明确设置了背景色的单元格。" },
    .{ .key = .@"background-blur", .en = "Whether to blur the background when `background-opacity` is less than 1.", .zh = "当 `background-opacity` 小于 1 时，是否模糊背景。" },
    .{ .key = .@"unfocused-split-opacity", .en = "The opacity level (opposite of transparency) of an unfocused split. Unfocused splits by default are slightly faded out to make it easier to see which split is focused. To disable this feature, set this value to 1.", .zh = "未聚焦分屏的不透明度（透明度的反面）。默认情况下，未聚焦的分屏会稍微变淡，方便看出哪个分屏有焦点。要关闭这个效果，把值设为 1。" },
    .{ .key = .@"unfocused-split-fill", .en = "The color to dim the unfocused split. Unfocused splits are dimmed by rendering a semi-transparent rectangle over the split. This sets the color of that rectangle and can be used to carefully control the dimming effect.", .zh = "让未聚焦分屏变暗用的颜色。变暗的做法是在分屏上盖一个半透明矩形。这里设置的就是该矩形的颜色，可用来精细控制变暗的效果。" },
    .{ .key = .@"split-divider-color", .en = "The color of the split divider. If this is not set, a default will be chosen. Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.", .zh = "分屏分隔线的颜色。不设置时会选用默认值。可写成十六进制（`#RRGGBB` 或 `RRGGBB`），或 X11 颜色名。" },
    .{ .key = .@"split-preserve-zoom", .en = "Control when Ghostty preserves a zoomed split. Under normal circumstances, any operation that changes focus or layout of the split tree in a window will unzoom any zoomed split. This configuration allows you to control this behavior.", .zh = "控制 Ghostty 何时保留已放大的分屏。通常，窗口里任何改变焦点或分屏树布局的操作，都会取消分屏的放大。这项配置让你控制这一行为。" },
    .{ .key = .@"search-foreground", .en = "The foreground and background color for search matches. This only applies to non-focused search matches, also known as candidate matches.", .zh = "搜索匹配项的前景色和背景色。只用于未聚焦的搜索匹配项，也叫候选匹配项。" },
    .{ .key = .@"search-selected-foreground", .en = "The foreground and background color for the currently selected search match. This is the focused match that will be jumped to when using next/previous search navigation.", .zh = "当前选中搜索匹配项的前景色和背景色。这是使用“下一个/上一个”搜索导航时会跳到的聚焦匹配项。" },
    .{ .key = .command, .en = "The command to run, usually a shell. If this is not an absolute path, it'll be looked up in the `PATH`. If this is not set, a default will be looked up from your system. The rules for the default lookup are:", .zh = "要运行的命令，通常是 shell。如果不是绝对路径，会在 `PATH` 中查找。如果不设置，会从你的系统查找默认值。默认值的查找规则如下：" },
    .{ .key = .@"initial-command", .en = "This is the same as \"command\", but only applies to the first terminal surface created when Ghostty starts. Subsequent terminal surfaces will use the `command` configuration.", .zh = "与 \"command\" 相同，但只用于 Ghostty 启动时创建的第一个终端。之后的终端使用 `command` 配置。" },
    .{ .key = .@"notify-on-command-finish", .en = "Controls when command finished notifications are sent. There are three options:", .zh = "控制何时发送命令结束通知。有三个选项：" },
    .{ .key = .@"notify-on-command-finish-action", .en = "If command finished notifications are enabled, this controls how the user is notified.", .zh = "如果启用了命令结束通知，这里控制如何通知用户。" },
    .{ .key = .@"notify-on-command-finish-after", .en = "If command finished notifications are enabled, this controls how long a command must have been running before a notification will be sent. The default is five seconds.", .zh = "如果启用了命令结束通知，这里控制命令至少运行多久才会发送通知。默认为五秒。" },
    .{ .key = .@"poltergeist-mcp", .en = "Let agents running in this terminal reach Poltergeist over a local socket, through the `polter +mcp` MCP server.", .zh = "让在此终端里运行的 agent 通过本地 socket，经 `polter +mcp` MCP 服务器连上 Poltergeist。" },
    .{ .key = .@"poltergeist-max-agents", .en = "How many agents may hold the socket at once.", .zh = "同时最多允许多少个 agent 占用该 socket。" },
    .{ .key = .@"poltergeist-render-mailbox-capacity", .en = "Lower the renderer mailbox's capacity, so that a full mailbox can be reached deliberately. **Zero, the default, means the built-in bound.**", .zh = "调小渲染器邮箱的容量，以便能有意让邮箱装满。**默认值 0 表示使用内置上限。**" },
    .{ .key = .@"poltergeist-register-mcp", .en = "Register Polter as an MCP server with Claude Code, so that agents in any directory can reach it.", .zh = "把 Polter 注册为 Claude Code 的 MCP 服务器，这样任何目录里的 agent 都能连上它。" },
    .{ .key = .@"poltergeist-watch", .en = "Watch this terminal for quiescence.", .zh = "监视此终端是否静止。" },
    .{ .key = .@"poltergeist-quiescence-after", .en = "How long the visible screen must go unchanged before this terminal is considered quiescent.", .zh = "屏幕上可见内容保持不变多久后，才认为该终端静止。" },
    .{ .key = .@"poltergeist-quiescence-repeat", .en = "How long to wait before reporting a terminal that is *still* quiescent.", .zh = "对仍然静止的终端，隔多久再报告一次。" },
    .{ .key = .@"poltergeist-notice-interval", .en = "How often the supervisor may be interrupted with what it has not seen.", .zh = "总管最短隔多久可被打断一次，告知它还没看到的内容。" },
    .{ .key = .@"poltergeist-task-idle-after", .en = "How long a task may go untouched before it is worth a line.", .zh = "任务无人动过多久后，值得提一句。" },
    .{ .key = .@"poltergeist-worker-nudge-after", .en = "How long a worker's screen may be still before it is reminded to report.", .zh = "worker 的屏幕静止多久后，提醒它汇报。" },
    .{ .key = .@"poltergeist-group-quiet-after", .en = "How long a group may be silent before it is worth a line.", .zh = "群沉默多久后，值得提一句。" },
    .{ .key = .@"poltergeist-calls-silent-after", .en = "How long a watched terminal may go without calling a Polter tool before that is worth a line.", .zh = "受监视的终端没调用 Polter 工具多久后，值得提一句。" },
    .{ .key = .@"poltergeist-stall-warn-after", .en = "How long Polter's app thread may spend on one thing before it is written in the log.", .zh = "Polter 的应用线程在一件事上停留多久后，会写进日志。" },
    .{ .key = .@"poltergeist-compact-after", .en = "How much uncompacted conversation a group may carry before the supervisor is reminded to tidy it.", .zh = "群里积累多少未整理的对话后，提醒总管整理。" },
    .{ .key = .@"poltergeist-supervisor-stand-down", .en = "Whether a supervisor may take itself off duty.", .zh = "总管是否可以自己下岗。" },
    .{ .key = .@"poltergeist-may-authorise", .en = "Whether a supervisor may answer a permission prompt in another terminal -- the `terminal_answer_prompt` tool and the keys that take an option in one -- when you have not said otherwise for that terminal.", .zh = "在你没有为某个终端另行设定时，总管是否可以回答另一个终端里的权限提示——即 `terminal_answer_prompt` 工具，以及选中提示里某个选项的按键。" },
    .{ .key = .@"poltergeist-pane-frames", .en = "Draw each pane of a split with the frame of what is in it.", .zh = "给分屏的每个窗格画上与其内容相符的边框。" },
    .{ .key = .@"poltergeist-worktree-location", .en = "Where a worktree goes when a supervisor opens a terminal with one (`terminal_open` or `role_launch` with `worktree`).", .zh = "总管用 worktree 打开终端时（`terminal_open`，或带 `worktree` 的 `role_launch`），worktree 放在哪里。" },
    .{ .key = .@"polter-control-room-at-launch", .en = "Open the control room when Polter starts.", .zh = "Polter 启动时打开总控台。" },
    .{ .key = .@"poltergeist-chat-log", .en = "Write what the terminals say to each other to disk.", .zh = "把终端之间的对话写到磁盘。" },
    .{ .key = .@"poltergeist-terminal-log", .en = "Keep a transcript of what actually ran in each terminal.", .zh = "保存每个终端里实际运行过的内容的记录。" },
    .{ .key = .@"poltergeist-terminal-log-keep-days", .en = "How many days of a terminal's transcript are kept when, at the time it was written, the terminal was in no group and no project. `unlimited` keeps them for ever.", .zh = "写下记录时不在任何群、也不在任何项目里的终端，其记录保留多少天。`unlimited` 表示永久保留。" },
    .{ .key = .@"poltergeist-terminal-log-max-mb", .en = "How many megabytes of transcript, of terminals that were in no group and no project, are kept in all. Past it the oldest files go until what is left fits. `unlimited` sets no total.", .zh = "不在任何群、也不在任何项目里的终端，其记录一共保留多少 MB。超出后从最旧的文件删起，直到剩下的不超限。`unlimited` 表示不设总量上限。" },
    .{ .key = .@"poltergeist-terminal-log-project-keep-days", .en = "How many days of transcript are kept from terminals that were in a project's tab but in no group. `unlimited` keeps them for ever.", .zh = "在某个项目的标签页里、但不在任何群中的终端，其记录保留多少天。`unlimited` 表示永久保留。" },
    .{ .key = .@"poltergeist-terminal-log-project-max-mb", .en = "How many megabytes of transcript are kept, in all, from terminals that were in a project's tab but in no group.", .zh = "在某个项目的标签页里、但不在任何群中的终端，其记录一共保留多少 MB。" },
    .{ .key = .@"poltergeist-terminal-log-group-max-mb", .en = "How many megabytes of transcript are kept, in all, from terminals that were members of a group at the time.", .zh = "当时是某个群成员的终端，其记录一共保留多少 MB。" },
    .{ .key = .@"poltergeist-log-keep-days", .en = "How many days of Polter's own logs are kept: plugins' older log generations, crash reports, the hourly group snapshots, and on Windows the host's log files. `unlimited` keeps them for ever.", .zh = "Polter 自己的日志保留多少天，包括插件较旧的日志、崩溃报告、每小时的群快照，以及 Windows 上宿主的日志文件。`unlimited` 表示永久保留。" },
    .{ .key = .@"poltergeist-log-max-mb", .en = "How many megabytes of Polter's own logs are kept in all. Past it the oldest go until what is left fits. A log being written now is never deleted.", .zh = "Polter 自己的日志一共保留多少 MB。超出后从最旧的删起，直到剩下的不超限。正在写入的日志永远不会被删除。" },
    .{ .key = .@"poltergeist-shots-keep-days", .en = "How many days of screenshots are kept in the screenshot directory. Only Polter's own screenshots are ever deleted, never anything else in that directory.", .zh = "截图目录里的截图保留多少天。只会删除 Polter 自己的截图，目录里的其他文件不会动。" },
    .{ .key = .@"poltergeist-shots-max-mb", .en = "How many megabytes of screenshots are kept in all.", .zh = "截图一共保留多少 MB。" },
    .{ .key = .@"poltergeist-notify", .en = "Deprecated, and does nothing.", .zh = "已弃用，不起作用。" },
    .{ .key = .@"poltergeist-notify-window", .en = "When it is acceptable to disturb you, as `HH:MM-HH:MM` in local time.", .zh = "什么时段可以打扰你，写成本地时间的 `HH:MM-HH:MM`。" },
    .{ .key = .env, .en = "Extra environment variables to pass to commands launched in a terminal surface. The format is `env=KEY=VALUE`.", .zh = "传给在终端里启动的命令的额外环境变量。格式为 `env=KEY=VALUE`。" },
    .{ .key = .input, .en = "Data to send as input to the command on startup.", .zh = "启动时作为输入发送给命令的数据。" },
    .{ .key = .@"wait-after-command", .en = "If true, keep the terminal open after the command exits. Normally, the terminal window closes when the running command (such as a shell) exits. With this true, the terminal window will stay open until any keypress is received.", .zh = "设为 true 时，命令退出后保持终端打开。通常，运行的命令（如 shell）退出后，终端窗口就关闭。设为 true 后，终端窗口会一直开着，直到收到任意按键。" },
    .{ .key = .@"abnormal-command-exit-runtime", .en = "The number of milliseconds of runtime below which we consider a process exit to be abnormal. This is used to show an error message when the process exits too quickly.", .zh = "运行时间低于多少毫秒的进程退出，会被视为异常。进程退出得太快时，据此显示错误信息。" },
    .{ .key = .@"scrollback-limit-bytes", .en = "The size of the scrollback buffer in bytes. This also includes the active screen. No matter what this is set to, enough memory will always be allocated for the visible screen and anything leftover is the limit for the scrollback.", .zh = "回滚缓冲区的大小，单位为字节，包含当前活动屏幕。无论设为多少，总会为可见屏幕分配足够的内存，剩下的才是回滚的上限。" },
    .{ .key = .@"scrollback-limit-lines", .en = "The maximum number of lines of scrollback to retain. This excludes the active screen. Soft-wrapped lines count as multiple lines.", .zh = "最多保留多少行回滚内容，不含当前活动屏幕。软换行的行按多行计算。" },
    .{ .key = .@"project-scrollback-limit-bytes", .en = "How much of each pane's scrollback is saved with a project, in bytes of saved file per pane. When the project is reopened, each pane shows what it last showed, back as far as this allowed. `0` saves nothing and restores nothing.", .zh = "随项目保存每个窗格回滚内容的量，单位为每个窗格保存文件的字节数。重新打开项目时，每个窗格会显示它上次显示的内容，在这个上限允许的范围内尽量往回。`0` 表示什么都不保存、什么都不恢复。" },
    .{ .key = .@"project-scrollback-autosave-interval", .en = "How often a pane that belongs to a project saves its scrollback while it runs, so that a crash, a forced restart or a power cut loses at most this much. A pane with no output since the last save writes nothing. Each save writes only what changed -- new pages of history and the visible screen -- not the whole scrollback again.", .zh = "属于某个项目的窗格在运行时隔多久保存一次回滚内容，这样崩溃、强制重启或断电最多丢失这么长时间的内容。自上次保存后没有新输出的窗格不会写入。每次只写变化的部分——新增的历史页和可见屏幕——而不是再写一遍整个回滚内容。" },
    .{ .key = .@"scrollback-compression", .en = "Whether to compress scrollback pages while the terminal is idle.", .zh = "终端空闲时，是否压缩回滚页。" },
    .{ .key = .scrollbar, .en = "Control when the scrollbar is shown to scroll the scrollback buffer.", .zh = "控制何时显示用于滚动回滚缓冲区的滚动条。" },
    .{ .key = .link, .en = "Match a regular expression against the terminal text and associate clicking it with an action. This can be used to match URLs, file paths, etc. Actions can be opening using the system opener (e.g. `open` or `xdg-open`) or executing any arbitrary binding action.", .zh = "用正则表达式匹配终端文本，并把点击匹配到的内容与某个动作关联。可用来匹配 URL、文件路径等。动作可以是用系统打开程序（如 `open` 或 `xdg-open`）打开，也可以是执行任意绑定动作。" },
    .{ .key = .@"link-url", .en = "Enable URL matching. URLs are matched on hover with control (Linux) or command (macOS) pressed and open using the default system application for the linked URL.", .zh = "启用 URL 匹配。按住 control（Linux）或 command（macOS）悬停时匹配 URL，并用该 URL 对应的系统默认应用打开。" },
    .{ .key = .@"link-osc8", .en = "Enable hyperlinks created with the OSC 8 escape sequence. When disabled, OSC 8 hyperlinks are not highlighted, previewed, copied, or opened.", .zh = "启用用 OSC 8 转义序列创建的超链接。禁用后，OSC 8 超链接不会被高亮、预览、复制或打开。" },
    .{ .key = .@"link-previews", .en = "Show link previews for a matched URL.", .zh = "为匹配到的 URL 显示链接预览。" },
    .{ .key = .maximize, .en = "Whether to start the window in a maximized state. This setting applies to new windows and does not apply to tabs, splits, etc. However, this setting will apply to all new windows, not just the first one.", .zh = "新窗口是否以最大化状态启动。此设置适用于新窗口，不适用于标签页、分屏等。不过它对所有新窗口都生效，而不只是第一个。" },
    .{ .key = .fullscreen, .en = "Start new windows in fullscreen. This setting applies to new windows and does not apply to tabs, splits, etc. However, this setting will apply to all new windows, not just the first one.", .zh = "新窗口以全屏启动。此设置适用于新窗口，不适用于标签页、分屏等。不过它对所有新窗口都生效，而不只是第一个。" },
    .{ .key = .title, .en = "The title Ghostty will use for the window. This will force the title of the window to be this title at all times and Ghostty will ignore any set title escape sequences programs (such as Neovim) may send.", .zh = "Ghostty 为窗口使用的标题。这会强制窗口标题始终是它，Ghostty 会忽略程序（如 Neovim）可能发来的设置标题的转义序列。" },
    .{ .key = .class, .en = "The setting that will change the application class value.", .zh = "用来改变应用 class 值的设置。" },
    .{ .key = .@"x11-instance-name", .en = "This controls the instance name field of the `WM_CLASS` X11 property when running under X11. It has no effect otherwise.", .zh = "在 X11 下运行时，控制 `WM_CLASS` X11 属性的实例名字段。其他情况下无效。" },
    .{ .key = .@"working-directory", .en = "The directory to change to after starting the command.", .zh = "启动命令后要切换到的目录。" },
    .{ .key = .keybind, .en = "Key bindings. The format is `trigger=action`. Duplicate triggers will overwrite previously set values. The list of actions is available in the documentation or using the `ghostty +list-actions` command.", .zh = "按键绑定。格式为 `trigger=action`。重复的触发键会覆盖之前设置的值。动作列表可在文档中查到，也可用 `ghostty +list-actions` 命令查看。" },
    .{ .key = .@"key-remap", .en = "Remap modifier keys within Ghostty. This allows you to swap or reassign modifier keys at the application level without affecting system-wide settings.", .zh = "在 Ghostty 内部重映射修饰键。可在应用层面交换或重新分配修饰键，而不影响系统全局设置。" },
    .{ .key = .@"window-padding-x", .en = "Horizontal window padding. This applies padding between the terminal cells and the left and right window borders. The value is in points, meaning that it will be scaled appropriately for screen DPI.", .zh = "窗口的水平内边距。指终端单元格与窗口左右边框之间的空白。单位是点，会按屏幕 DPI 适当缩放。" },
    .{ .key = .@"window-padding-y", .en = "Vertical window padding. This applies padding between the terminal cells and the top and bottom window borders. The value is in points, meaning that it will be scaled appropriately for screen DPI.", .zh = "窗口的垂直内边距。指终端单元格与窗口上下边框之间的空白。单位是点，会按屏幕 DPI 适当缩放。" },
    .{ .key = .@"window-padding-balance", .en = "The viewport dimensions are usually not perfectly divisible by the cell size. In this case, some extra padding on the end of a column and the bottom of the final row may exist. If this is `true`, then this extra padding is automatically balanced between all four edges to minimize imbalance on one side. If this is `false`, the top left grid cell will always hug the edge with zero padding other than what may be specified with the other `window-padding` options.", .zh = "可视区域的尺寸通常不能被单元格大小整除，因此一列的末尾和最后一行的底部可能留有多余的空白。设为 `true` 时，这些多余空白会自动平均分到四条边，尽量减少一侧偏多。设为 `false` 时，左上角的单元格总是紧贴边缘，内边距只有其他 `window-padding` 选项指定的那些。" },
    .{ .key = .@"window-padding-color", .en = "The color of the padding area of the window. Valid values are:", .zh = "窗口内边距区域的颜色。有效值为：" },
    .{ .key = .@"window-vsync", .en = "Synchronize rendering with the screen refresh rate. If true, this will minimize tearing and align redraws with the screen but may cause input latency. If false, this will maximize redraw frequency but may cause tearing, and under heavy load may use more CPU and power.", .zh = "让渲染与屏幕刷新率同步。设为 true 时，可减少画面撕裂并使重绘与屏幕对齐，但可能带来输入延迟。设为 false 时，重绘频率最高，但可能画面撕裂，并且在高负载下可能占用更多 CPU 和电量。" },
    .{ .key = .@"window-inherit-working-directory", .en = "If true, new windows will inherit the working directory of the previously focused window. If no window was previously focused, the default working directory will be used (the `working-directory` option).", .zh = "设为 true 时，新窗口继承上一个获得焦点的窗口的工作目录。如果之前没有窗口获得过焦点，则使用默认工作目录（`working-directory` 选项）。" },
    .{ .key = .@"tab-inherit-working-directory", .en = "If true, new tabs will inherit the working directory of the previously focused tab. If no tab was previously focused, the default working directory will be used (the `working-directory` option).", .zh = "设为 true 时，新标签页继承上一个获得焦点的标签页的工作目录。如果之前没有标签页获得过焦点，则使用默认工作目录（`working-directory` 选项）。" },
    .{ .key = .@"split-inherit-working-directory", .en = "If true, new split panes will inherit the working directory of the previously focused split. If no split was previously focused, the default working directory will be used (the `working-directory` option).", .zh = "设为 true 时，新分屏继承上一个获得焦点的分屏的工作目录。如果之前没有分屏获得过焦点，则使用默认工作目录（`working-directory` 选项）。" },
    .{ .key = .@"window-inherit-font-size", .en = "If true, new windows and tabs will inherit the font size of the previously focused window. If no window was previously focused, the default font size will be used. If this is false, the default font size specified in the configuration `font-size` will be used.", .zh = "设为 true 时，新窗口和新标签页继承上一个获得焦点的窗口的字号。如果之前没有窗口获得过焦点，则使用默认字号。设为 false 时，使用配置项 `font-size` 指定的默认字号。" },
    .{ .key = .@"window-decoration", .en = "Configure a preference for window decorations. This setting specifies a _preference_; the actual OS, desktop environment, window manager, etc. may override this preference. Ghostty will do its best to respect this preference but it may not always be possible.", .zh = "设置对窗口装饰的偏好。这里指定的是一个偏好；实际的操作系统、桌面环境、窗口管理器等可能会覆盖它。Ghostty 会尽量遵循，但不一定总能做到。" },
    .{ .key = .@"window-title-font-family", .en = "The font that will be used for the application's window and tab titles.", .zh = "应用窗口标题和标签页标题所用的字体。" },
    .{ .key = .@"window-subtitle", .en = "The text that will be displayed in the subtitle of the window. Valid values:", .zh = "显示在窗口副标题里的文字。有效值：" },
    .{ .key = .@"window-theme", .en = "The theme to use for the windows. Valid values:", .zh = "窗口使用的主题。有效值：" },
    .{ .key = .@"window-colorspace", .en = "The color space to use when interpreting terminal colors. \"Terminal colors\" refers to colors specified in your configuration and colors produced by direct-color SGR sequences.", .zh = "解释终端颜色时使用的色彩空间。“终端颜色”指配置里指定的颜色，以及直接颜色 SGR 序列产生的颜色。" },
    .{ .key = .@"window-height", .en = "The initial window size. This size is in terminal grid cells by default. Both values must be set to take effect. If only one value is set, it is ignored.", .zh = "初始窗口大小。默认以终端网格单元格为单位。两个值都设置才生效；只设置一个时会被忽略。" },
    .{ .key = .@"window-position-x", .en = "The starting window position. This position is in pixels and is relative to the top-left corner of the primary monitor. Both values must be set to take effect. If only one value is set, it is ignored.", .zh = "窗口的起始位置。单位是像素，相对于主显示器的左上角。两个值都设置才生效；只设置一个时会被忽略。" },
    .{ .key = .@"window-save-state", .en = "Whether to enable saving and restoring window state. Window state includes their position, size, tabs, splits, etc. Some window state requires shell integration, such as preserving working directories. See `shell-integration` for more information.", .zh = "是否启用窗口状态的保存与恢复。窗口状态包括位置、大小、标签页、分屏等。某些窗口状态需要 shell 集成，比如保留工作目录。详见 `shell-integration`。" },
    .{ .key = .@"window-step-resize", .en = "Resize the window in discrete increments of the focused surface's cell size. If this is disabled, surfaces are resized in pixel increments. Currently only supported on macOS.", .zh = "按当前终端单元格大小的整数倍调整窗口大小。禁用时，终端按像素调整大小。目前只有 macOS 支持。" },
    .{ .key = .@"window-new-tab-position", .en = "The position where new tabs are created. Valid values:", .zh = "新标签页创建的位置。有效值：" },
    .{ .key = .@"window-show-tab-bar", .en = "Whether to show the tab bar.", .zh = "是否显示标签栏。" },
    .{ .key = .@"window-titlebar-background", .en = "Background color for the window titlebar. This only takes effect if window-theme is set to ghostty. Currently only supported in the GTK app runtime.", .zh = "窗口标题栏的背景色。只有 window-theme 设为 ghostty 时才生效。目前只有 GTK 应用运行时支持。" },
    .{ .key = .@"window-titlebar-foreground", .en = "Foreground color for the window titlebar. This only takes effect if window-theme is set to ghostty. Currently only supported in the GTK app runtime.", .zh = "窗口标题栏的前景色。只有 window-theme 设为 ghostty 时才生效。目前只有 GTK 应用运行时支持。" },
    .{ .key = .@"drag-handle", .en = "Controls when drag handles are shown over splits, allowing splits to be rearranged with mouse controls.", .zh = "控制何时在分屏上显示拖动手柄，以便用鼠标重新排列分屏。" },
    .{ .key = .@"resize-overlay", .en = "This controls when resize overlays are shown. Resize overlays are a transient popup that shows the size of the terminal while the surfaces are being resized. The possible options are:", .zh = "控制何时显示调整大小的浮层。调整大小浮层是一个临时弹出的提示，在调整终端大小时显示终端的尺寸。可选项为：" },
    .{ .key = .@"resize-overlay-position", .en = "If resize overlays are enabled, this controls the position of the overlay. The possible options are:", .zh = "启用调整大小浮层时，控制浮层的位置。可选项为：" },
    .{ .key = .@"resize-overlay-duration", .en = "If resize overlays are enabled, this controls how long the overlay is visible on the screen before it is hidden. The default is ¾ of a second or 750 ms.", .zh = "启用调整大小浮层时，控制浮层在屏幕上显示多久后隐藏。默认为 ¾ 秒，即 750 毫秒。" },
    .{ .key = .@"focus-follows-mouse", .en = "If true, when there are multiple split panes, the mouse selects the pane that is focused. This only applies to the currently focused window; e.g. mousing over a split in an unfocused window will not focus that split and bring the window to front.", .zh = "设为 true 时，有多个分屏的情况下，鼠标所在的分屏获得焦点。这只适用于当前获得焦点的窗口；例如，鼠标移到未获得焦点的窗口里的分屏上，不会让该分屏获得焦点，也不会把窗口提到最前。" },
    .{ .key = .@"clipboard-read", .en = "Whether to allow programs running in the terminal to read/write to the system clipboard (OSC 52, for googling). The default is to allow clipboard reading after prompting the user and allow writing unconditionally.", .zh = "是否允许终端里运行的程序读取或写入系统剪贴板（OSC 52，可搜索了解）。默认是询问用户后允许读取，写入则无条件允许。" },
    .{ .key = .@"clipboard-write-limit-bytes", .en = "The maximum size in bytes of a single clipboard write by a program running in the terminal via the Kitty clipboard protocol (OSC 5522). This doesn't apply to OSC 52, which is limited by the maximum length of an escape sequence hardcoded into Ghostty for now.", .zh = "终端里运行的程序通过 Kitty 剪贴板协议（OSC 5522）一次写入剪贴板的最大字节数。这不适用于 OSC 52，它目前受 Ghostty 内置的转义序列最大长度限制。" },
    .{ .key = .@"clipboard-trim-trailing-spaces", .en = "Trims trailing whitespace on data that is copied to the clipboard. This does not affect data sent to the clipboard via `clipboard-write`. This only applies to trailing whitespace on lines that have other characters. Completely blank lines always have their whitespace trimmed.", .zh = "去掉复制到剪贴板的数据末尾的空白。这不影响通过 `clipboard-write` 发到剪贴板的数据。只作用于含有其他字符的行的末尾空白；完全空白的行，其空白总是会被去掉。" },
    .{ .key = .@"clipboard-paste-protection", .en = "Require confirmation before pasting text that appears unsafe. This helps prevent a \"copy/paste attack\" where a user may accidentally execute unsafe commands by pasting text with newlines.", .zh = "粘贴看起来不安全的文本前要求确认。这有助于防止“复制粘贴攻击”，即用户粘贴带换行的文本时，不小心执行了不安全的命令。" },
    .{ .key = .@"clipboard-paste-bracketed-safe", .en = "If true, bracketed pastes will be considered safe. By default, bracketed pastes are considered safe. \"Bracketed\" pastes are pastes while the running program has bracketed paste mode enabled (a setting set by the running program, not the terminal emulator).", .zh = "设为 true 时，括号式粘贴被视为安全。默认就视为安全。“括号式”粘贴是指运行中的程序启用了括号粘贴模式（这是运行中的程序设置的，不是终端模拟器的设置）时的粘贴。" },
    .{ .key = .@"clipboard-paste-image", .en = "Paste an image that is on the clipboard as the path of a file holding it.", .zh = "把剪贴板上的图片粘贴为存放该图片的文件路径。" },
    .{ .key = .@"screenshot-directory", .en = "The directory screenshots and pasted clipboard images are written to.", .zh = "截图和粘贴的剪贴板图片写入的目录。" },
    .{ .key = .@"screenshot-mouse-trigger", .en = "The modifier keys that, held while clicking the left mouse button anywhere on screen, take a screenshot -- the second way to start one, for when one hand is already on the mouse. The keyboard way is the `screenshot` keybind action.", .zh = "在屏幕任意位置按住这些修饰键并点击鼠标左键，就会截图——这是启动截图的第二种方式，适合一只手已经放在鼠标上的时候。键盘方式是 `screenshot` 按键绑定动作。" },
    .{ .key = .@"screenshot-agent-access", .en = "Whether an agent running in a Polter terminal may take screenshots.", .zh = "在 Polter 终端里运行的 agent 是否可以截图。" },
    .{ .key = .@"title-report", .en = "Enables or disabled title reporting (CSI 21 t). This escape sequence allows the running program to query the terminal title. This is a common security issue and is disabled by default.", .zh = "启用或禁用标题上报（CSI 21 t）。这个转义序列允许运行中的程序查询终端标题。这是常见的安全问题，默认禁用。" },
    .{ .key = .@"image-storage-limit", .en = "The total amount of bytes that can be used for image data (e.g. the Kitty image protocol) per terminal screen. The maximum value is 4,294,967,295 (4GiB). The default is 320MB. If this is set to zero, then all image protocols will be disabled.", .zh = "每个终端屏幕可用于图像数据（如 Kitty 图像协议）的总字节数。最大值为 4,294,967,295（4GiB），默认为 320MB。设为 0 时，所有图像协议都会被禁用。" },
    .{ .key = .@"copy-on-select", .en = "Whether to automatically copy selected text to the clipboard.", .zh = "是否自动把选中的文本复制到剪贴板。" },
    .{ .key = .@"right-click-action", .en = "The action to take when the user right-clicks on the terminal surface.", .zh = "用户在终端上点击鼠标右键时执行的动作。" },
    .{ .key = .@"middle-click-action", .en = "The action to take when the user middle-clicks on the terminal surface.", .zh = "用户在终端上点击鼠标中键时执行的动作。" },
    .{ .key = .@"click-repeat-interval", .en = "The time in milliseconds between clicks to consider a click a repeat (double, triple, etc.) or an entirely new single click. A value of zero will use a platform-specific default. The default on macOS is determined by the OS settings. On every other platform it is 500ms.", .zh = "两次点击相隔多少毫秒以内，算作重复点击（双击、三击等），否则算全新的单击。设为 0 时使用平台特有的默认值。macOS 上的默认值由系统设置决定，其他平台为 500 毫秒。" },
    .{ .key = .@"config-file", .en = "Additional configuration files to read. This configuration can be repeated to read multiple configuration files. Configuration files themselves can load more configuration files. Paths are relative to the file containing the `config-file` directive. For command-line arguments, paths are relative to the current working directory.", .zh = "要额外读取的配置文件。这项配置可重复，以读取多个配置文件。配置文件本身也可以再加载更多配置文件。路径相对于包含该 `config-file` 指令的文件；命令行参数里的路径相对于当前工作目录。" },
    .{ .key = .@"config-default-files", .en = "When this is true, the default configuration file paths will be loaded. The default configuration file paths are currently only the XDG config path ($XDG_CONFIG_HOME/ghostty/config.ghostty).", .zh = "为 true 时，加载默认配置文件路径。默认配置文件路径目前只有 XDG 配置路径（$XDG_CONFIG_HOME/ghostty/config.ghostty）。" },
    .{ .key = .@"confirm-close-surface", .en = "Confirms that a surface should be closed before closing it.", .zh = "关闭终端前先确认。" },
    .{ .key = .@"quit-after-last-window-closed", .en = "Whether or not to quit after the last surface is closed.", .zh = "最后一个终端关闭后是否退出。" },
    .{ .key = .@"quit-after-last-window-closed-delay", .en = "Controls how long Ghostty will stay running after the last open surface has been closed. This only has an effect if `quit-after-last-window-closed` is also set to `true`.", .zh = "最后一个打开的终端关闭后，Ghostty 继续运行多久。只有 `quit-after-last-window-closed` 也设为 `true` 时才有效。" },
    .{ .key = .@"initial-window", .en = "This controls whether an initial window is created when Ghostty is run. Note that if `quit-after-last-window-closed` is `true` and `quit-after-last-window-closed-delay` is set, setting `initial-window` to `false` will mean that Ghostty will quit after the configured delay if no window is ever created. Only implemented on Linux and macOS.", .zh = "控制运行 Ghostty 时是否创建初始窗口。注意：如果 `quit-after-last-window-closed` 为 `true` 且设置了 `quit-after-last-window-closed-delay`，把 `initial-window` 设为 `false` 意味着，若一直没有创建过窗口，Ghostty 会在配置的延迟后退出。只在 Linux 和 macOS 上实现。" },
    .{ .key = .@"undo-timeout", .en = "The duration that undo operations remain available. After this time, the operation will be removed from the undo stack and cannot be undone.", .zh = "撤销操作保持可用的时长。超过这个时间，操作会从撤销栈中移除，无法再撤销。" },
    .{ .key = .@"quick-terminal-position", .en = "The position of the \"quick\" terminal window. To learn more about the quick terminal, see the documentation for the `toggle_quick_terminal` binding action.", .zh = "“快速”终端窗口的位置。关于快速终端，详见 `toggle_quick_terminal` 绑定动作的文档。" },
    .{ .key = .@"quick-terminal-size", .en = "The size of the quick terminal.", .zh = "快速终端的大小。" },
    .{ .key = .@"gtk-quick-terminal-layer", .en = "The layer of the quick terminal window. The higher the layer, the more windows the quick terminal may conceal.", .zh = "快速终端窗口所在的层。层越高，快速终端能遮住的窗口越多。" },
    .{ .key = .@"gtk-quick-terminal-namespace", .en = "The namespace for the quick terminal window.", .zh = "快速终端窗口的命名空间。" },
    .{ .key = .@"quick-terminal-screen", .en = "The screen where the quick terminal should show up.", .zh = "快速终端应显示在哪块屏幕上。" },
    .{ .key = .@"quick-terminal-animation-duration", .en = "Duration (in seconds) of the quick terminal enter and exit animation. Set it to 0 to disable animation completely. This can be changed at runtime.", .zh = "快速终端进入和退出动画的时长（秒）。设为 0 可完全关闭动画。可在运行时修改。" },
    .{ .key = .@"quick-terminal-autohide", .en = "Automatically hide the quick terminal when focus shifts to another window. Set it to false for the quick terminal to remain open even when it loses focus.", .zh = "焦点移到其他窗口时自动隐藏快速终端。设为 false 则快速终端即使失去焦点也保持打开。" },
    .{ .key = .@"quick-terminal-space-behavior", .en = "This configuration option determines the behavior of the quick terminal when switching between macOS spaces. macOS spaces are virtual desktops that can be manually created or are automatically created when an application is in full-screen mode.", .zh = "这项配置决定在 macOS 的空间之间切换时，快速终端的行为。macOS 的空间是虚拟桌面，可以手动创建，应用进入全屏模式时也会自动创建。" },
    .{ .key = .@"quick-terminal-keyboard-interactivity", .en = "Determines under which circumstances that the quick terminal should receive keyboard input. See the corresponding [Wayland documentation](https://wayland.app/protocols/wlr-layer-shell-unstable-v1#zwlr_layer_surface_v1:enum:keyboard_interactivity) for a more detailed explanation of the behavior of each option.", .zh = "决定在什么情况下快速终端应接收键盘输入。每个选项行为的详细说明，见对应的 [Wayland 文档](https://wayland.app/protocols/wlr-layer-shell-unstable-v1#zwlr_layer_surface_v1:enum:keyboard_interactivity)。" },
    .{ .key = .@"shell-integration", .en = "Whether to enable shell integration auto-injection or not. Shell integration greatly enhances the terminal experience by enabling a number of features:", .zh = "是否启用 shell 集成的自动注入。Shell 集成启用多项功能，能大大改善终端体验：" },
    .{ .key = .@"shell-integration-features", .en = "Shell integration features to enable. These require our shell integration to be loaded, either automatically via shell-integration or manually.", .zh = "要启用的 shell 集成功能。这些功能需要先加载我们的 shell 集成，加载方式可以是通过 shell-integration 自动加载，也可以手动加载。" },
    .{ .key = .@"command-palette-entry", .en = "Custom entries into the command palette.", .zh = "命令面板的自定义条目。" },
    .{ .key = .@"osc-color-report-format", .en = "Sets the reporting format for OSC sequences that request color information. Ghostty currently supports OSC 10 (foreground), OSC 11 (background), and OSC 4 (256 color palette) queries, and by default the reported values are scaled-up RGB values, where each component are 16 bits. This is how most terminals report these values. However, some legacy applications may require 8-bit, unscaled, components. We also support turning off reporting altogether. The components are lowercase hex values.", .zh = "设置请求颜色信息的 OSC 序列的上报格式。Ghostty 目前支持 OSC 10（前景色）、OSC 11（背景色）和 OSC 4（256 色调色板）查询，默认上报放大后的 RGB 值，每个分量 16 位。大多数终端都是这样上报这些值的。不过，一些老旧程序可能需要 8 位、未放大的分量。我们也支持完全关闭上报。分量为小写十六进制值。" },
    .{ .key = .@"vt-kam-allowed", .en = "If true, allows the \"KAM\" mode (ANSI mode 2) to be used within the terminal. KAM disables keyboard input at the request of the application. This is not a common feature and is not recommended to be enabled. This will not be documented further because if you know you need KAM, you know. If you don't know if you need KAM, you don't need it.", .zh = "设为 true 时，允许在终端里使用 “KAM” 模式（ANSI 模式 2）。KAM 会应程序要求禁用键盘输入。这不是常见功能，不建议启用。这里不再多作说明：如果你知道自己需要 KAM，你就知道；如果你不知道自己是否需要 KAM，那就不需要。" },
    .{ .key = .@"custom-shader", .en = "Custom shaders to run after the default shaders. This is a file path to a GLSL-syntax shader for all platforms.", .zh = "在默认着色器之后运行的自定义着色器。这是一个 GLSL 语法着色器的文件路径，所有平台通用。" },
    .{ .key = .@"custom-shader-animation", .en = "If `true` (default), the focused terminal surface will run an animation loop when custom shaders are used. This uses slightly more CPU (generally less than 10%) but allows the shader to animate. This only runs if there are custom shaders and the terminal is focused.", .zh = "为 `true`（默认）时，使用自定义着色器的情况下，获得焦点的终端会运行动画循环。这会稍多占用一点 CPU（通常不到 10%），但让着色器能够产生动画。只有存在自定义着色器且终端获得焦点时才会运行。" },
    .{ .key = .@"bell-features", .en = "Bell features to enable if bell support is available in your runtime. Not all features are available on all runtimes. The format of this is a list of features to enable separated by commas. If you prefix a feature with `no-` then it is disabled. If you omit a feature, its default value is used.", .zh = "在你的运行环境支持响铃时，要启用的响铃功能。并非所有运行环境都提供所有功能。格式是用逗号分隔的、要启用的功能列表。功能前加 `no-` 表示禁用。省略的功能使用其默认值。" },
    .{ .key = .@"bell-audio-path", .en = "If `audio` is an enabled bell feature, this is a path to an audio file. If the path is not absolute, it is considered relative to the directory of the configuration file that it is referenced from, or from the current working directory if this is used as a CLI flag. The path may be prefixed with `~/` to reference the user's home directory.", .zh = "如果 `audio` 是已启用的响铃功能，这里是音频文件的路径。路径不是绝对路径时，相对于引用它的配置文件所在目录；若是作为命令行参数使用，则相对于当前工作目录。路径可以用 `~/` 开头表示用户主目录。" },
    .{ .key = .@"bell-audio-volume", .en = "If `audio` is an enabled bell feature, this is the volume to play the audio file at (relative to the system volume). This is a floating point number ranging from 0.0 (silence) to 1.0 (as loud as possible). The default is 0.5.", .zh = "如果 `audio` 是已启用的响铃功能，这里是播放音频文件的音量（相对于系统音量）。这是一个浮点数，范围从 0.0（静音）到 1.0（最大声）。默认为 0.5。" },
    .{ .key = .@"app-notifications", .en = "Control the in-app notifications that Ghostty shows.", .zh = "控制 Ghostty 显示的应用内通知。" },
    .{ .key = .@"macos-non-native-fullscreen", .en = "If anything other than false, fullscreen mode on macOS will not use the native fullscreen, but make the window fullscreen without animations and using a new space. It's faster than the native fullscreen mode since it doesn't use animations.", .zh = "不是 false 时，macOS 上的全屏模式不使用原生全屏，而是不带动画、使用新空间让窗口全屏。因为没有动画，它比原生全屏模式更快。" },
    .{ .key = .@"macos-window-buttons", .en = "Whether the window buttons in the macOS titlebar are visible. The window buttons are the colored buttons in the upper left corner of most macOS apps, also known as the traffic lights, that allow you to close, miniaturize, and zoom the window.", .zh = "macOS 标题栏里的窗口按钮是否可见。窗口按钮是大多数 macOS 应用左上角的彩色按钮，也叫红绿灯，可用来关闭、最小化和缩放窗口。" },
    .{ .key = .@"macos-titlebar-style", .en = "The style of the macOS titlebar. Available values are: \"native\", \"transparent\", \"tabs\", and \"hidden\".", .zh = "macOS 标题栏的样式。可用值为：\"native\"、\"transparent\"、\"tabs\" 和 \"hidden\"。" },
    .{ .key = .@"macos-titlebar-proxy-icon", .en = "Whether the proxy icon in the macOS titlebar is visible. The proxy icon is the icon that represents the folder of the current working directory. You can see this very clearly in the macOS built-in Terminal.app titlebar.", .zh = "macOS 标题栏里的代理图标是否可见。代理图标表示当前工作目录所在文件夹的图标。在 macOS 自带的“终端”标题栏里能很清楚地看到。" },
    .{ .key = .@"macos-dock-drop-behavior", .en = "Controls the windowing behavior when dropping a file or folder onto the Ghostty icon in the macOS dock.", .zh = "控制把文件或文件夹拖放到 macOS 程序坞里的 Ghostty 图标上时的窗口行为。" },
    .{ .key = .@"macos-option-as-alt", .en = "macOS doesn't have a distinct \"alt\" key and instead has the \"option\" key which behaves slightly differently. On macOS by default, the option key plus a character will sometimes produce a Unicode character. For example, on US standard layouts option-b produces \"∫\". This may be undesirable if you want to use \"option\" as an \"alt\" key for keybindings in terminal programs or shells.", .zh = "macOS 没有单独的 “alt” 键，而是有行为略有不同的 “option” 键。在 macOS 上默认情况下，option 键加一个字符有时会产生 Unicode 字符。例如，在美式标准键盘布局上 option-b 会产生 “∫”。如果你想把 “option” 当作 “alt” 键，用于终端程序或 shell 里的按键绑定，这可能并不合适。" },
    .{ .key = .@"macos-window-shadow", .en = "Whether to enable the macOS window shadow. The default value is true. With some window managers and window transparency settings, you may find false more visually appealing.", .zh = "是否启用 macOS 窗口阴影。默认值为 true。在某些窗口管理器和窗口透明度设置下，设为 false 可能在视觉上更好看。" },
    .{ .key = .@"macos-hidden", .en = "If true, the macOS icon in the dock and app switcher will be hidden. This is mainly intended for those primarily using the quick-terminal mode.", .zh = "设为 true 时，隐藏程序坞和应用切换器中的 macOS 图标。主要面向主要使用快速终端模式的用户。" },
    .{ .key = .@"macos-auto-secure-input", .en = "If true, Ghostty on macOS will automatically enable the \"Secure Input\" feature when it detects that a password prompt is being displayed.", .zh = "设为 true 时，macOS 上的 Ghostty 检测到正在显示密码提示符时，会自动启用“安全输入”功能。" },
    .{ .key = .@"macos-secure-input-indication", .en = "If true, Ghostty will show a graphical indication when secure input is enabled. This indication is generally recommended to know when secure input is enabled.", .zh = "设为 true 时，启用安全输入后 Ghostty 会显示图形提示。一般建议保留这个提示，以便知道安全输入何时开启。" },
    .{ .key = .@"windows-secure-input-exclude-from-capture", .en = "Keep the window out of screen captures while secure input is on.", .zh = "安全输入开启期间，让窗口不出现在屏幕捕获中。" },
    .{ .key = .@"macos-applescript", .en = "If true, Ghostty exposes and handles the built-in AppleScript dictionary on macOS.", .zh = "设为 true 时，Ghostty 在 macOS 上提供并处理内置的 AppleScript 词典。" },
    .{ .key = .@"macos-icon", .en = "Customize the macOS app icon.", .zh = "自定义 macOS 应用图标。" },
    .{ .key = .@"macos-custom-icon", .en = "The absolute path to the custom icon file. Supported formats include PNG, JPEG, and ICNS.", .zh = "自定义图标文件的绝对路径。支持 PNG、JPEG 和 ICNS 格式。" },
    .{ .key = .@"macos-icon-frame", .en = "The material to use for the frame of the macOS app icon.", .zh = "macOS 应用图标边框所用的材质。" },
    .{ .key = .@"macos-icon-ghost-color", .en = "The color of the ghost in the macOS app icon.", .zh = "macOS 应用图标中幽灵的颜色。" },
    .{ .key = .@"macos-icon-screen-color", .en = "The color of the screen in the macOS app icon.", .zh = "macOS 应用图标中屏幕的颜色。" },
    .{ .key = .@"macos-shortcuts", .en = "Whether macOS Shortcuts are allowed to control Ghostty.", .zh = "是否允许 macOS“快捷指令”控制 Ghostty。" },
    .{ .key = .@"linux-cgroup", .en = "Put every surface (tab, split, window) into a transient `systemd` scope.", .zh = "把每个终端（标签页、分屏、窗口）放进临时的 `systemd` scope。" },
    .{ .key = .@"linux-cgroup-memory-limit", .en = "Memory limit for any individual terminal process (tab, split, window, etc.) in bytes. If this is unset then no memory limit will be set.", .zh = "任一单个终端进程（标签页、分屏、窗口等）的内存上限，单位为字节。不设置则不限制内存。" },
    .{ .key = .@"linux-cgroup-processes-limit", .en = "Number of processes limit for any individual terminal process (tab, split, window, etc.). If this is unset then no limit will be set.", .zh = "任一单个终端进程（标签页、分屏、窗口等）的进程数上限。不设置则不限制。" },
    .{ .key = .@"linux-cgroup-hard-fail", .en = "If this is false, then creating a transient `systemd` scope (for `linux-cgroup`) will be allowed to fail and the failure is ignored. This is useful if you view cgroup isolation as a \"nice to have\" and not a critical resource management feature, because surface creation will not fail if `systemd` APIs fail.", .zh = "设为 false 时，创建临时 `systemd` scope（用于 `linux-cgroup`）允许失败，失败会被忽略。如果你把 cgroup 隔离看作“有最好、没有也行”，而不是关键的资源管理功能，这很有用，因为 `systemd` API 失败时，终端的创建不会随之失败。" },
    .{ .key = .@"gtk-opengl-debug", .en = "Enable or disable GTK's OpenGL debugging logs. The default is `true` for debug builds, `false` for all others.", .zh = "启用或禁用 GTK 的 OpenGL 调试日志。调试构建默认为 `true`，其他构建默认为 `false`。" },
    .{ .key = .@"gtk-single-instance", .en = "If `true`, the Ghostty GTK application will run in single-instance mode: each new `ghostty` process launched will result in a new window if there is already a running process.", .zh = "为 `true` 时，Ghostty GTK 应用以单实例模式运行：已有进程在运行时，每启动一个新的 `ghostty` 进程，都会得到一个新窗口。" },
    .{ .key = .@"gtk-titlebar", .en = "When enabled, the full GTK titlebar is displayed instead of your window manager's simple titlebar. The behavior of this option will vary with your window manager.", .zh = "启用时，显示完整的 GTK 标题栏，而不是窗口管理器的简易标题栏。这个选项的行为会因窗口管理器而异。" },
    .{ .key = .@"gtk-tabs-location", .en = "Determines the side of the screen that the GTK tab bar will stick to. Top, bottom, and hidden are supported. The default is top.", .zh = "决定 GTK 标签栏贴靠屏幕的哪一侧。支持顶部、底部和隐藏。默认为顶部。" },
    .{ .key = .@"gtk-titlebar-hide-when-maximized", .en = "If this is `true`, the titlebar will be hidden when the window is maximized, and shown when the titlebar is unmaximized. GTK only.", .zh = "为 `true` 时，窗口最大化后隐藏标题栏，取消最大化后再显示。仅限 GTK。" },
    .{ .key = .@"gtk-toolbar-style", .en = "Determines the appearance of the top and bottom bars tab bar.", .zh = "决定顶部和底部标签栏的外观。" },
    .{ .key = .@"gtk-titlebar-style", .en = "The style of the GTK titlebar. Available values are `native` and `tabs`.", .zh = "GTK 标题栏的样式。可用值为 `native` 和 `tabs`。" },
    .{ .key = .@"gtk-wide-tabs", .en = "If `true` (default), then the Ghostty GTK tabs will be \"wide.\" Wide tabs are the new typical Gnome style where tabs fill their available space. If you set this to `false` then tabs will only take up space they need, which is the old style.", .zh = "为 `true`（默认）时，Ghostty GTK 标签页是“宽”的。宽标签页是新的 Gnome 典型样式，标签页会占满可用空间。设为 `false` 时，标签页只占用所需的空间，这是旧样式。" },
    .{ .key = .@"gtk-horizontal-tab-scroll", .en = "If `true` (default), then two-finger horizontal scrolling on a touchpad will switch between tabs. Scrolling left goes to the next tab and scrolling right goes to the previous tab. Set this to `false` to disable this behavior.", .zh = "为 `true`（默认）时，在触控板上用两指横向滚动可切换标签页。向左滚动到下一个标签页，向右滚动到上一个标签页。设为 `false` 可关闭这一行为。" },
    .{ .key = .@"gtk-custom-css", .en = "Custom CSS files to be loaded.", .zh = "要加载的自定义 CSS 文件。" },
    .{ .key = .@"desktop-notifications", .en = "If `true` (default), applications running in the terminal can show desktop notifications using certain escape sequences such as OSC 9 or OSC 777.", .zh = "为 `true`（默认）时，终端里运行的应用可以用某些转义序列（如 OSC 9 或 OSC 777）显示桌面通知。" },
    .{ .key = .@"progress-style", .en = "If `true` (default), applications running in the terminal can show graphical progress bars using the ConEmu OSC 9;4 escape sequence. If `false`, progress bar sequences are silently ignored.", .zh = "为 `true`（默认）时，终端里运行的应用可以用 ConEmu 的 OSC 9;4 转义序列显示图形进度条。为 `false` 时，进度条序列会被静默忽略。" },
    .{ .key = .@"bold-color", .en = "Modifies the color used for bold text in the terminal.", .zh = "修改终端里粗体文字所用的颜色。" },
    .{ .key = .@"faint-opacity", .en = "The opacity level (opposite of transparency) of the faint text. A value of 1 is fully opaque and a value of 0 is fully transparent. A value less than 0 or greater than 1 will be clamped to the nearest valid value.", .zh = "暗淡文字的不透明度（透明度的反面）。1 为完全不透明，0 为完全透明。小于 0 或大于 1 的值会被限制到最近的有效值。" },
    .{ .key = .term, .en = "This will be used to set the `TERM` environment variable. HACK: We set this with an `xterm` prefix because vim uses that to enable key protocols (specifically this will enable `modifyOtherKeys`), among other features. An option exists in vim to modify this: `:set keyprotocol=ghostty:kitty`, however a bug in the implementation prevents it from working properly. https://github.com/vim/vim/pull/13211 fixes this.", .zh = "用于设置 `TERM` 环境变量。取巧做法：我们给它加了 `xterm` 前缀，因为 vim 据此启用按键协议（具体是启用 `modifyOtherKeys`）等功能。vim 里有一个选项可以修改这一点：`:set keyprotocol=ghostty:kitty`，但实现里的一个 bug 使它不能正常工作。https://github.com/vim/vim/pull/13211 修复了这个问题。" },
    .{ .key = .@"enquiry-response", .en = "String to send when we receive `ENQ` (`0x05`) from the command that we are running. Defaults to an empty string if not set.", .zh = "收到所运行命令发来的 `ENQ`（`0x05`）时发送的字符串。不设置则默认为空字符串。" },
    .{ .key = .@"async-backend", .en = "Configures the low-level API to use for async IO, eventing, etc.", .zh = "配置用于异步 IO、事件等的底层 API。" },
    .{ .key = .@"auto-update", .en = "Control the auto-update functionality of Ghostty. This is only supported on macOS currently, since Linux builds are distributed via package managers that are not centrally controlled by Ghostty.", .zh = "控制 Ghostty 的自动更新功能。目前只有 macOS 支持，因为 Linux 版本通过包管理器分发，Ghostty 无法集中控制。" },
    .{ .key = .@"auto-update-channel", .en = "The release channel to use for auto-updates.", .zh = "自动更新使用的发布渠道。" },
};
