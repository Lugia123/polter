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
    .{
        .key = .@"cursor-style-blink",
        .en = "Sets the default blinking state of the cursor. This is just the default state; running programs may override the cursor style using `DECSCUSR` (`CSI q`).",
        .zh = "光标默认是否闪烁。这只是默认状态；运行中的程序可以用 `DECSCUSR`（`CSI q`）改变光标样式。",
        .full_en =
        \\Sets the default blinking state of the cursor. This is just the default
        \\state; running programs may override the cursor style using `DECSCUSR` (`CSI
        \\q`).
        \\
        \\If this is not set, the cursor blinks by default. Note that this is not the
        \\same as a "true" value, as noted below.
        \\
        \\If this is not set at all (`null`), then Ghostty will respect DEC Mode 12
        \\(AT&T cursor blink) as an alternate approach to turning blinking on/off. If
        \\this is set to any value other than null, DEC mode 12 will be ignored but
        \\`DECSCUSR` will still be respected.
        \\
        \\Valid values are:
        \\
        \\  * ` ` (blank)
        \\  * `true`
        \\  * `false`
        ,
        .full_zh =
        \\光标默认是否闪烁。这只是默认状态；运行中的程序可以用 `DECSCUSR`（`CSI q`）改变光标样式。
        \\
        \\不设置时，光标默认闪烁。注意这和设为 "true" 不是一回事，见下文。
        \\
        \\如果完全不设置（`null`），Ghostty 会遵从 DEC 模式 12（AT&T 光标闪烁），作为开关闪烁的另一种方式。只要设为 null 以外的任何值，DEC 模式 12 就会被忽略，但 `DECSCUSR` 仍然有效。
        \\
        \\有效值：
        \\
        \\  * ` `（留空）
        \\  * `true`
        \\  * `false`
        ,
    },
    .{ .key = .@"cursor-text", .en = "The color of the text under the cursor. If this is not set, a default will be chosen. Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color. Since version 1.2.0, this can also be set to `cell-foreground` to match the cell foreground color, or `cell-background` to match the cell background color.", .zh = "光标下文字的颜色。不设置时会选用默认值。可写成十六进制（`#RRGGBB` 或 `RRGGBB`），或 X11 颜色名。自 1.2.0 版起，也可设为 `cell-foreground`（与单元格前景色一致）或 `cell-background`（与单元格背景色一致）。" },
    .{
        .key = .@"cursor-click-to-move",
        .en = "Enables the ability to move the cursor at prompts by clicking on a location in the prompt text.",
        .zh = "允许在提示符处点击提示符文本中的某个位置来移动光标。",
        .full_en =
        \\Enables the ability to move the cursor at prompts by clicking on a
        \\location in the prompt text.
        \\
        \\This feature requires prompt marking via `OSC 133`. Some shells like Fish
        \\(v4.1+) and Nu (0.111+) natively support this while others may require
        \\additional configuration or Ghostty's shell integration features to be
        \\enabled.
        \\
        \\Depending on the shell, this works either by translating your click
        \\position into a series of synthetic arrow key movements or by sending
        \\a click event directly to the shell. In either case, some unexpected
        \\behavior around edge cases is possible.
        ,
        .full_zh =
        \\允许在提示符处点击提示符文本中的某个位置来移动光标。
        \\
        \\这项功能需要通过 `OSC 133` 标记提示符。有些 shell（如 Fish v4.1+、Nu 0.111+）原生支持；其他 shell 可能需要额外配置，或者启用 Ghostty 的 shell 集成功能。
        \\
        \\视 shell 而定，它的做法要么是把你点击的位置换算成一串模拟的方向键移动，要么是把点击事件直接发给 shell。无论哪种，在一些边界情况下都可能出现意料之外的行为。
        ,
    },
    .{ .key = .@"mouse-hide-while-typing", .en = "Hide the mouse immediately when typing. The mouse becomes visible again when the mouse is used (button, movement, etc.). Platform-specific behavior may dictate other scenarios where the mouse is shown. For example on macOS, the mouse is shown again when a new window, tab, or split is created.", .zh = "输入时立即隐藏鼠标。再次使用鼠标（按键、移动等）时鼠标重新显示。平台特有的行为可能规定在其他情形下也显示鼠标。例如在 macOS 上，新建窗口、标签页或分屏时会重新显示鼠标。" },
    .{
        .key = .@"scroll-to-bottom",
        .en = "When to scroll the surface to the bottom. The format of this is a list of options to enable separated by commas. If you prefix an option with `no-` then it is disabled. If you omit an option, its default value is used.",
        .zh = "何时把终端滚动到底部。格式是用逗号分隔的、要启用的选项列表。选项前加 `no-` 表示禁用。省略的选项使用其默认值。",
        .full_en =
        \\When to scroll the surface to the bottom. The format of this is a list of
        \\options to enable separated by commas. If you prefix an option with `no-`
        \\then it is disabled. If you omit an option, its default value is used.
        \\
        \\Available options:
        \\
        \\- `keystroke` If set, scroll the surface to the bottom when the user
        \\  presses a key that results in data being sent to the PTY (basically
        \\  anything but modifiers or keybinds that are processed by Ghostty).
        \\
        \\- `output` If set, scroll the surface to the bottom if there is new data
        \\  to display (e.g., when new lines are printed to the terminal).
        \\
        \\The default is `keystroke, no-output`.
        ,
        .full_zh =
        \\何时把终端滚动到底部。格式是用逗号分隔的、要启用的选项列表。选项前加 `no-` 表示禁用。省略的选项使用其默认值。
        \\
        \\可用选项：
        \\
        \\- `keystroke`：设置后，用户按下会向 PTY 发送数据的键时（基本上除修饰键和由 Ghostty 处理的快捷键以外的所有键），把终端滚动到底部。
        \\
        \\- `output`：设置后，有新内容要显示时（例如终端打印了新的行），把终端滚动到底部。
        \\
        \\默认值是 `keystroke, no-output`。
        ,
    },
    .{
        .key = .@"mouse-shift-capture",
        .en = "Determines whether running programs can detect the shift key pressed with a mouse click. Typically, the shift key is used to extend mouse selection.",
        .zh = "决定运行中的程序能否检测到鼠标点击时按下了 Shift 键。通常 Shift 键用来扩展鼠标选区。",
        .full_en =
        \\Determines whether running programs can detect the shift key pressed with a
        \\mouse click. Typically, the shift key is used to extend mouse selection.
        \\
        \\The default value of `false` means that the shift key is not sent with
        \\the mouse protocol and will extend the selection. This value can be
        \\conditionally overridden by the running program with the `XTSHIFTESCAPE`
        \\sequence.
        \\
        \\The value `true` means that the shift key is sent with the mouse protocol
        \\but the running program can override this behavior with `XTSHIFTESCAPE`.
        \\
        \\The value `never` is the same as `false` but the running program cannot
        \\override this behavior with `XTSHIFTESCAPE`. The value `always` is the
        \\same as `true` but the running program cannot override this behavior with
        \\`XTSHIFTESCAPE`.
        \\
        \\If you always want shift to extend mouse selection even if the program
        \\requests otherwise, set this to `never`.
        \\
        \\Valid values are:
        \\
        \\  * `true`
        \\  * `false`
        \\  * `always`
        \\  * `never`
        ,
        .full_zh =
        \\决定运行中的程序能否检测到鼠标点击时按下了 Shift 键。通常 Shift 键用来扩展鼠标选区。
        \\
        \\默认值 `false` 表示 Shift 键不随鼠标协议发送，而是用来扩展选区。运行中的程序可以用 `XTSHIFTESCAPE` 序列有条件地改变这个值。
        \\
        \\值 `true` 表示 Shift 键随鼠标协议发送，但运行中的程序可以用 `XTSHIFTESCAPE` 改变这一行为。
        \\
        \\值 `never` 与 `false` 相同，但运行中的程序不能用 `XTSHIFTESCAPE` 改变这一行为。值 `always` 与 `true` 相同，但运行中的程序不能用 `XTSHIFTESCAPE` 改变这一行为。
        \\
        \\如果你希望 Shift 始终用来扩展鼠标选区，即使程序另有要求，就设为 `never`。
        \\
        \\有效值：
        \\
        \\  * `true`
        \\  * `false`
        \\  * `always`
        \\  * `never`
        ,
    },
    .{
        .key = .@"mouse-reporting",
        .en = "Enable or disable mouse reporting. When set to `false`, mouse events will not be reported to terminal applications even if they request it. This allows you to always use the mouse for selection and other terminal UI interactions without applications capturing mouse input.",
        .zh = "启用或禁用鼠标事件上报。设为 `false` 时，即使终端程序请求，也不会向它们上报鼠标事件。这样你可以始终用鼠标做选择和其他终端界面操作，而不被程序抢走鼠标输入。",
        .full_en =
        \\Enable or disable mouse reporting. When set to `false`, mouse events will
        \\not be reported to terminal applications even if they request it. This
        \\allows you to always use the mouse for selection and other terminal UI
        \\interactions without applications capturing mouse input.
        \\
        \\When set to `true` (the default), terminal applications can request mouse
        \\reporting and will receive mouse events according to their requested mode.
        \\
        \\This can be toggled at runtime using the `toggle_mouse_reporting` keybind
        \\action.
        ,
        .full_zh =
        \\启用或禁用鼠标事件上报。设为 `false` 时，即使终端程序请求，也不会向它们上报鼠标事件。这样你可以始终用鼠标做选择和其他终端界面操作，而不被程序抢走鼠标输入。
        \\
        \\设为 `true`（默认）时，终端程序可以请求鼠标上报，并按它请求的模式收到鼠标事件。
        \\
        \\运行时可以用快捷键动作 `toggle_mouse_reporting` 切换。
        ,
    },
    .{
        .key = .@"mouse-scroll-multiplier",
        .en = "Multiplier for scrolling distance with the mouse wheel.",
        .zh = "鼠标滚轮滚动距离的倍数。",
        .full_en =
        \\Multiplier for scrolling distance with the mouse wheel.
        \\
        \\A prefix of `precision:` or `discrete:` can be used to set the multiplier
        \\only for scrolling with the specific type of devices. These can be
        \\comma-separated to set both types of multipliers at the same time, e.g.
        \\`precision:0.1,discrete:3`. If no prefix is used, the multiplier applies
        \\to all scrolling devices. Specifying a prefix was introduced in Ghostty
        \\1.2.1.
        \\
        \\The value will be clamped to [0.01, 10,000]. Both of these are extreme
        \\and you're likely to have a bad experience if you set either extreme.
        \\
        \\The default value is "3" for discrete devices and "1" for precision devices.
        ,
        .full_zh =
        \\鼠标滚轮滚动距离的倍数。
        \\
        \\可以加前缀 `precision:` 或 `discrete:`，只为某一类设备设置倍数。两者可以用逗号隔开同时设置，例如 `precision:0.1,discrete:3`。不加前缀时，倍数对所有滚动设备生效。前缀写法自 Ghostty 1.2.1 起引入。
        \\
        \\取值会被限制在 [0.01, 10,000] 之间。这两头都很极端，设成任何一头，体验大概都不会好。
        \\
        \\默认值：分级滚动设备为 "3"，精确滚动设备为 "1"。
        ,
    },
    .{
        .key = .@"background-opacity",
        .en = "The opacity level (opposite of transparency) of the background. A value of 1 is fully opaque and a value of 0 is fully transparent. A value less than 0 or greater than 1 will be clamped to the nearest valid value.",
        .zh = "背景的不透明度（透明度的反面）。1 为完全不透明，0 为完全透明。小于 0 或大于 1 的值会被限制到最近的有效值。",
        .full_en =
        \\The opacity level (opposite of transparency) of the background. A value of
        \\1 is fully opaque and a value of 0 is fully transparent. A value less than 0
        \\or greater than 1 will be clamped to the nearest valid value.
        \\
        \\On macOS, background opacity is disabled when the terminal enters native
        \\fullscreen. This is because the background becomes gray and it can cause
        \\widgets to show through which isn't generally desirable.
        \\
        \\On macOS, changing this configuration requires restarting Ghostty completely.
        ,
        .full_zh =
        \\背景的不透明度（透明度的反面）。1 为完全不透明，0 为完全透明。小于 0 或大于 1 的值会被限制到最近的有效值。
        \\
        \\在 macOS 上，终端进入原生全屏时会停用背景不透明度。因为那时背景会变成灰色，而且下面的控件可能透出来，通常不是想要的效果。
        \\
        \\在 macOS 上，改这项配置需要完全重启 Ghostty。
        ,
    },
    .{
        .key = .@"background-opacity-cells",
        .en = "Applies background opacity to cells with an explicit background color set.",
        .zh = "把背景不透明度也应用到明确设置了背景色的单元格。",
        .full_en =
        \\Applies background opacity to cells with an explicit background color
        \\set.
        \\
        \\Normally, `background-opacity` is only applied to the window background.
        \\If a cell has an explicit background color set, such as red, then that
        \\background color will be fully opaque. An effect of this is that some
        \\terminal applications that repaint the background color of the terminal
        \\such as a Neovim and Tmux may not respect the `background-opacity`
        \\(by design).
        \\
        \\Setting this to `true` will apply the `background-opacity` to all cells
        \\regardless of whether they have an explicit background color set or not.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\把背景不透明度也应用到明确设置了背景色的单元格。
        \\
        \\通常 `background-opacity` 只作用于窗口背景。如果某个单元格明确设置了背景色（比如红色），这个背景色会完全不透明。这样一来，一些会重绘终端背景色的终端程序（如 Neovim 和 Tmux）可能就不遵从 `background-opacity`（这是有意为之）。
        \\
        \\设为 `true` 后，`background-opacity` 会作用于所有单元格，不管它们有没有明确设置背景色。
        \\
        \\自 1.2.0 起可用。
        ,
    },
    .{
        .key = .@"background-blur",
        .en = "Whether to blur the background when `background-opacity` is less than 1.",
        .zh = "当 `background-opacity` 小于 1 时，是否模糊背景。",
        .full_en =
        \\Whether to blur the background when `background-opacity` is less than 1.
        \\
        \\Valid values are:
        \\
        \\  * a nonnegative integer specifying the *blur intensity*
        \\  * `false`, equivalent to a blur intensity of 0
        \\  * `true`, equivalent to the default blur intensity of 20, which is
        \\    reasonable for a good looking blur. Higher blur intensities may
        \\    cause strange rendering and performance issues.
        \\
        \\On macOS 26.0 and later, there are additional special values that
        \\can be set to use the native macOS glass effects:
        \\
        \\  * `macos-glass-regular` - Standard glass effect with some opacity
        \\  * `macos-glass-clear` - Highly transparent glass effect
        \\
        \\If the macOS values are set, then this implies `background-blur = true`
        \\on non-macOS platforms.
        \\
        \\On Linux, the exact blur intensity is ignored and any positive integer
        \\or `true` value will enable background blur. On Wayland, Ghostty uses
        \\the [`ext-background-effect-v1`](https://wayland.app/protocols/ext-background-effect-v1)
        \\protocol to enable the blur effect, but this is not always supported
        \\on all compositors. Check the documentation of your compositor or
        \\desktop environment for blur support and how to configure it.
        \\
        \\On X11, blur can only be enabled when using the KWin compositor
        \\as a part of KDE Plasma.
        ,
        .full_zh =
        \\当 `background-opacity` 小于 1 时，是否模糊背景。
        \\
        \\有效值：
        \\
        \\  * 一个非负整数，表示*模糊强度*
        \\  * `false`，等同于模糊强度 0
        \\  * `true`，等同于默认的模糊强度 20，这个值足以得到好看的模糊效果。更高的模糊强度可能导致奇怪的渲染和性能问题。
        \\
        \\在 macOS 26.0 及更高版本上，还有一些特殊值，可以使用 macOS 原生的玻璃效果：
        \\
        \\  * `macos-glass-regular`：带一定不透明度的标准玻璃效果
        \\  * `macos-glass-clear`：高度透明的玻璃效果
        \\
        \\设了这些 macOS 专用值时，在非 macOS 平台上相当于 `background-blur = true`。
        \\
        \\在 Linux 上，具体的模糊强度会被忽略，任何正整数或 `true` 都会启用背景模糊。在 Wayland 上，Ghostty 使用 [`ext-background-effect-v1`](https://wayland.app/protocols/ext-background-effect-v1) 协议来启用模糊效果，但不是所有合成器都支持。请查阅你的合成器或桌面环境的文档，了解它是否支持模糊以及如何配置。
        \\
        \\在 X11 上，只有使用 KDE Plasma 里的 KWin 合成器时才能启用模糊。
        ,
    },
    .{
        .key = .@"unfocused-split-opacity",
        .en = "The opacity level (opposite of transparency) of an unfocused split. Unfocused splits by default are slightly faded out to make it easier to see which split is focused. To disable this feature, set this value to 1.",
        .zh = "未聚焦分屏的不透明度（透明度的反面）。默认情况下，未聚焦的分屏会稍微变淡，方便看出哪个分屏有焦点。要关闭这个效果，把值设为 1。",
        .full_en =
        \\The opacity level (opposite of transparency) of an unfocused split.
        \\Unfocused splits by default are slightly faded out to make it easier to see
        \\which split is focused. To disable this feature, set this value to 1.
        \\
        \\A value of 1 is fully opaque and a value of 0 is fully transparent. Because
        \\"0" is not useful (it makes the window look very weird), the minimum value
        \\is 0.15. This value still looks weird but you can at least see what's going
        \\on. A value outside of the range 0.15 to 1 will be clamped to the nearest
        \\valid value.
        ,
        .full_zh =
        \\未聚焦分屏的不透明度（透明度的反面）。默认情况下，未聚焦的分屏会稍微变淡，方便看出哪个分屏有焦点。要关闭这个效果，把值设为 1。
        \\
        \\1 为完全不透明，0 为完全透明。因为 "0" 没有用（窗口会看起来很怪），最小值是 0.15。这个值看起来仍然很怪，但至少能看清发生了什么。0.15 到 1 之外的值会被限制到最近的有效值。
        ,
    },
    .{
        .key = .@"unfocused-split-fill",
        .en = "The color to dim the unfocused split. Unfocused splits are dimmed by rendering a semi-transparent rectangle over the split. This sets the color of that rectangle and can be used to carefully control the dimming effect.",
        .zh = "让未聚焦分屏变暗用的颜色。变暗的做法是在分屏上盖一个半透明矩形。这里设置的就是该矩形的颜色，可用来精细控制变暗的效果。",
        .full_en =
        \\The color to dim the unfocused split. Unfocused splits are dimmed by
        \\rendering a semi-transparent rectangle over the split. This sets the color of
        \\that rectangle and can be used to carefully control the dimming effect.
        \\
        \\This will default to the background color.
        \\
        \\Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.
        ,
        .full_zh =
        \\让未聚焦分屏变暗用的颜色。变暗的做法是在分屏上盖一个半透明矩形。这里设置的就是该矩形的颜色，可用来精细控制变暗的效果。
        \\
        \\默认为背景色。
        \\
        \\可写成十六进制（`#RRGGBB` 或 `RRGGBB`），或 X11 颜色名。
        ,
    },
    .{
        .key = .@"split-divider-color",
        .en = "The color of the split divider. If this is not set, a default will be chosen. Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.",
        .zh = "分屏分隔线的颜色。不设置时会选用默认值。可写成十六进制（`#RRGGBB` 或 `RRGGBB`），或 X11 颜色名。",
        .full_en =
        \\The color of the split divider. If this is not set, a default will be chosen.
        \\Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.
        \\
        \\Available since: 1.1.0
        ,
        .full_zh =
        \\分屏分隔线的颜色。不设置时会选用默认值。可写成十六进制（`#RRGGBB` 或 `RRGGBB`），或 X11 颜色名。
        \\
        \\自 1.1.0 起可用。
        ,
    },
    .{
        .key = .@"split-preserve-zoom",
        .en = "Control when Ghostty preserves a zoomed split. Under normal circumstances, any operation that changes focus or layout of the split tree in a window will unzoom any zoomed split. This configuration allows you to control this behavior.",
        .zh = "控制 Ghostty 何时保留已放大的分屏。通常，窗口里任何改变焦点或分屏树布局的操作，都会取消分屏的放大。这项配置让你控制这一行为。",
        .full_en =
        \\Control when Ghostty preserves a zoomed split. Under normal circumstances,
        \\any operation that changes focus or layout of the split tree in a window
        \\will unzoom any zoomed split. This configuration allows you to control
        \\this behavior.
        \\
        \\This can be set to `navigation` to preserve the zoomed split state
        \\when navigating to another split (e.g. via `goto_split`). This will
        \\change the zoomed split to the newly focused split instead of unzooming.
        \\
        \\Any options can also be prefixed with `no-` to disable that option.
        \\
        \\Example: `split-preserve-zoom = navigation`
        \\
        \\Available since: 1.3.0
        ,
        .full_zh =
        \\控制 Ghostty 何时保留已放大的分屏。通常，窗口里任何改变焦点或分屏树布局的操作，都会取消分屏的放大。这项配置让你控制这一行为。
        \\
        \\设为 `navigation` 时，导航到另一个分屏（例如通过 `goto_split`）会保留放大状态：放大会转到新获得焦点的分屏上，而不是取消。
        \\
        \\任何选项都可以加前缀 `no-` 来禁用。
        \\
        \\示例：`split-preserve-zoom = navigation`
        \\
        \\自 1.3.0 起可用。
        ,
    },
    .{
        .key = .@"search-foreground",
        .en = "The foreground and background color for search matches. This only applies to non-focused search matches, also known as candidate matches.",
        .zh = "搜索匹配项的前景色和背景色。只用于未聚焦的搜索匹配项，也叫候选匹配项。",
        .full_en =
        \\The foreground and background color for search matches. This only applies
        \\to non-focused search matches, also known as candidate matches.
        \\
        \\Valid values:
        \\
        \\  - Hex (`#RRGGBB` or `RRGGBB`)
        \\  - Named X11 color
        \\  - "cell-foreground" to match the cell foreground color
        \\  - "cell-background" to match the cell background color
        \\
        \\The default value is black text on a golden yellow background.
        ,
        .full_zh =
        \\搜索匹配项的前景色和背景色。只用于未聚焦的搜索匹配项，也叫候选匹配项。
        \\
        \\有效值：
        \\
        \\  - 十六进制（`#RRGGBB` 或 `RRGGBB`）
        \\  - X11 颜色名
        \\  - "cell-foreground"：与单元格前景色一致
        \\  - "cell-background"：与单元格背景色一致
        \\
        \\默认是金黄色背景上的黑色文字。
        ,
    },
    .{
        .key = .@"search-selected-foreground",
        .en = "The foreground and background color for the currently selected search match. This is the focused match that will be jumped to when using next/previous search navigation.",
        .zh = "当前选中搜索匹配项的前景色和背景色。这是使用“下一个/上一个”搜索导航时会跳到的聚焦匹配项。",
        .full_en =
        \\The foreground and background color for the currently selected search match.
        \\This is the focused match that will be jumped to when using next/previous
        \\search navigation.
        \\
        \\Valid values:
        \\
        \\  - Hex (`#RRGGBB` or `RRGGBB`)
        \\  - Named X11 color
        \\  - "cell-foreground" to match the cell foreground color
        \\  - "cell-background" to match the cell background color
        \\
        \\The default value is black text on a soft peach background.
        ,
        .full_zh =
        \\当前选中搜索匹配项的前景色和背景色。这是使用“下一个/上一个”搜索导航时会跳到的聚焦匹配项。
        \\
        \\有效值：
        \\
        \\  - 十六进制（`#RRGGBB` 或 `RRGGBB`）
        \\  - X11 颜色名
        \\  - "cell-foreground"：与单元格前景色一致
        \\  - "cell-background"：与单元格背景色一致
        \\
        \\默认是浅桃色背景上的黑色文字。
        ,
    },
    .{
        .key = .command,
        .en = "The command to run, usually a shell. If this is not an absolute path, it'll be looked up in the `PATH`. If this is not set, a default will be looked up from your system. The rules for the default lookup are:",
        .zh = "要运行的命令，通常是 shell。如果不是绝对路径，会在 `PATH` 中查找。如果不设置，会从你的系统查找默认值。默认值的查找规则如下：",
        .full_en =
        \\The command to run, usually a shell. If this is not an absolute path, it'll
        \\be looked up in the `PATH`. If this is not set, a default will be looked up
        \\from your system. The rules for the default lookup are:
        \\
        \\  * `SHELL` environment variable
        \\
        \\  * `passwd` entry (user information)
        \\
        \\This can contain additional arguments to run the command with. If additional
        \\arguments are provided, the command will be executed using `/bin/sh -c`
        \\to offload shell argument expansion.
        \\
        \\To avoid shell expansion altogether, prefix the command with `direct:`, e.g.
        \\`direct:nvim foo`. This will avoid the roundtrip to `/bin/sh` but will also
        \\not support any shell parsing such as arguments with spaces, filepaths with
        \\`~`, globs, etc. (Available since: 1.2.0)
        \\
        \\You can also explicitly prefix the command with `shell:` to always wrap the
        \\command in a shell. This can be used to ensure our heuristics to choose the
        \\right mode are not used in case they are wrong. (Available since: 1.2.0)
        \\
        \\This command will be used for all new terminal surfaces, i.e. new windows,
        \\tabs, etc. If you want to run a command only for the first terminal surface
        \\created when Ghostty starts, use the `initial-command` configuration.
        \\
        \\Ghostty supports the common `-e` flag for executing a command with
        \\arguments. For example, `ghostty -e fish --with --custom --args`.
        \\This flag sets the `initial-command` configuration, see that for more
        \\information.
        ,
        .full_zh =
        \\要运行的命令，通常是 shell。如果不是绝对路径，会在 `PATH` 中查找。如果不设置，会从你的系统查找默认值。默认值的查找规则如下：
        \\
        \\  * 环境变量 `SHELL`
        \\
        \\  * `passwd` 条目（用户信息）
        \\
        \\可以带上运行命令所用的额外参数。带了额外参数时，命令会通过 `/bin/sh -c` 执行，由它展开 shell 参数。
        \\
        \\要完全避免 shell 展开，在命令前加 `direct:`，例如 `direct:nvim foo`。这样省去了经过 `/bin/sh` 的一趟，但也不再支持任何 shell 解析，比如带空格的参数、带 `~` 的路径、通配符等。（自 1.2.0 起可用）
        \\
        \\也可以明确在命令前加 `shell:`，总是用 shell 包起命令。万一我们选择模式的判断出错，可以用它来绕开这套判断。（自 1.2.0 起可用）
        \\
        \\这个命令用于所有新建的终端，即新窗口、新标签页等。如果只想在 Ghostty 启动时创建的第一个终端里运行某个命令，请用 `initial-command` 配置。
        \\
        \\Ghostty 支持常见的 `-e` 参数来执行带参数的命令，例如 `ghostty -e fish --with --custom --args`。这个参数设置的是 `initial-command` 配置，详见那一项。
        ,
    },
    .{
        .key = .@"initial-command",
        .en = "This is the same as \"command\", but only applies to the first terminal surface created when Ghostty starts. Subsequent terminal surfaces will use the `command` configuration.",
        .zh = "与 \"command\" 相同，但只用于 Ghostty 启动时创建的第一个终端。之后的终端使用 `command` 配置。",
        .full_en =
        \\This is the same as "command", but only applies to the first terminal
        \\surface created when Ghostty starts. Subsequent terminal surfaces will use
        \\the `command` configuration.
        \\
        \\After the first terminal surface is created (or closed), there is no
        \\way to run this initial command again automatically. As such, setting
        \\this at runtime works but will only affect the next terminal surface
        \\if it is the first one ever created.
        \\
        \\If you're using the `ghostty` CLI there is also a shortcut to set this
        \\with arguments directly: you can use the `-e` flag. For example: `ghostty -e
        \\fish --with --custom --args`. The `-e` flag automatically forces some
        \\other behaviors as well:
        \\
        \\  * Disables shell expansion since the input is expected to already
        \\    be shell-expanded by the upstream (e.g. the shell used to type in
        \\    the `ghostty -e` command).
        \\
        \\  * `gtk-single-instance=false` - This ensures that a new instance is
        \\    launched and the CLI args are respected.
        \\
        \\  * `quit-after-last-window-closed=true` - This ensures that the Ghostty
        \\    process will exit when the command exits. Additionally, the
        \\    `quit-after-last-window-closed-delay` is unset.
        \\
        \\  * `shell-integration=detect` (if not `none`) - This prevents forcibly
        \\    injecting any configured shell integration into the command's
        \\    environment. With `-e` its highly unlikely that you're executing a
        \\    shell and forced shell integration is likely to cause problems
        \\    (e.g. by wrapping your command in a shell, setting env vars, etc.).
        \\    This is a safety measure to prevent unexpected behavior. If you want
        \\    shell integration with a `-e`-executed command, you must either
        \\    name your binary appropriately or source the shell integration script
        \\    manually.
        ,
        .full_zh =
        \\与 "command" 相同，但只用于 Ghostty 启动时创建的第一个终端。之后的终端使用 `command` 配置。
        \\
        \\第一个终端创建（或关闭）以后，就没有办法再自动运行这个初始命令了。所以在运行时设置它也可以，但只有在下一个终端恰好是有史以来第一个时才会生效。
        \\
        \\如果你用的是 `ghostty` 命令行，还有一个直接带参数设置它的快捷方式：用 `-e` 参数，例如 `ghostty -e fish --with --custom --args`。`-e` 参数还会自动强制以下几项行为：
        \\
        \\  * 禁用 shell 展开，因为输入应该已经由上游（例如你用来输入 `ghostty -e` 命令的那个 shell）展开过了。
        \\
        \\  * `gtk-single-instance=false`：确保启动一个新实例，并遵从命令行参数。
        \\
        \\  * `quit-after-last-window-closed=true`：确保命令退出时 Ghostty 进程也退出。此外，`quit-after-last-window-closed-delay` 会被取消设置。
        \\
        \\  * `shell-integration=detect`（如果原来不是 `none`）：避免把配置的 shell 集成强行注入命令的环境。用 `-e` 时，你执行的几乎不会是 shell，强行注入 shell 集成很可能出问题（例如把你的命令包进 shell、设置环境变量等）。这是防止意外行为的安全措施。如果你确实希望用 `-e` 执行的命令带上 shell 集成，就得给你的程序起一个合适的名字，或者手动 source shell 集成脚本。
        ,
    },
    .{
        .key = .@"notify-on-command-finish",
        .en = "Controls when command finished notifications are sent. There are three options:",
        .zh = "控制何时发送命令结束通知。有三个选项：",
        .full_en =
        \\Controls when command finished notifications are sent. There are
        \\three options:
        \\
        \\* `never` - Never send notifications (the default).
        \\* `unfocused` - Only send notifications if the surface that the command is
        \\  running in is not focused.
        \\* `always` - Always send notifications.
        \\
        \\Command finished notifications requires that either shell integration is
        \\enabled, or that your shell sends OSC 133 escape sequences to mark the start
        \\and end of commands.
        \\
        \\On GTK, there is a context menu item that will enable command finished
        \\notifications for a single command, overriding the `never` and `unfocused`
        \\options.
        \\
        \\Available since 1.3.0.
        ,
        .full_zh =
        \\控制何时发送命令结束通知。有三个选项：
        \\
        \\* `never`：从不发送通知（默认）。
        \\* `unfocused`：只在命令所在的终端没有焦点时发送通知。
        \\* `always`：总是发送通知。
        \\
        \\命令结束通知要求启用 shell 集成，或者你的 shell 会发送 OSC 133 转义序列来标记命令的开始和结束。
        \\
        \\在 GTK 上，右键菜单里有一项可以只为单个命令启用命令结束通知，覆盖 `never` 和 `unfocused` 选项。
        \\
        \\自 1.3.0 起可用。
        ,
    },
    .{
        .key = .@"notify-on-command-finish-action",
        .en = "If command finished notifications are enabled, this controls how the user is notified.",
        .zh = "如果启用了命令结束通知，这里控制如何通知用户。",
        .full_en =
        \\If command finished notifications are enabled, this controls how the user is
        \\notified.
        \\
        \\Available options:
        \\
        \\* `bell` - enabled by default
        \\* `notify` - disabled by default
        \\
        \\Options can be combined by listing them as a comma separated list. Options
        \\can be negated by prefixing them with `no-`. For example `no-bell,notify`.
        \\
        \\Available since 1.3.0.
        ,
        .full_zh =
        \\如果启用了命令结束通知，这里控制如何通知用户。
        \\
        \\可用选项：
        \\
        \\* `bell`：默认启用
        \\* `notify`：默认不启用
        \\
        \\选项可以写成逗号分隔的列表来组合。选项前加 `no-` 表示取反。例如 `no-bell,notify`。
        \\
        \\自 1.3.0 起可用。
        ,
    },
    .{
        .key = .@"notify-on-command-finish-after",
        .en = "If command finished notifications are enabled, this controls how long a command must have been running before a notification will be sent. The default is five seconds.",
        .zh = "如果启用了命令结束通知，这里控制命令至少运行多久才会发送通知。默认为五秒。",
        .full_en =
        \\If command finished notifications are enabled, this controls how long a
        \\command must have been running before a notification will be sent. The
        \\default is five seconds.
        \\
        \\The duration is specified as a series of numbers followed by time units.
        \\Whitespace is allowed between numbers and units. Each number and unit will
        \\be added together to form the total duration.
        \\
        \\The allowed time units are as follows:
        \\
        \\  * `y` - 365 SI days, or 8760 hours, or 31536000 seconds. No adjustments
        \\    are made for leap years or leap seconds.
        \\  * `d` - one SI day, or 86400 seconds.
        \\  * `h` - one hour, or 3600 seconds.
        \\  * `m` - one minute, or 60 seconds.
        \\  * `s` - one second.
        \\  * `ms` - one millisecond, or 0.001 second.
        \\  * `us` or `µs` - one microsecond, or 0.000001 second.
        \\  * `ns` - one nanosecond, or 0.000000001 second.
        \\
        \\Examples:
        \\  * `1h30m`
        \\  * `45s`
        \\
        \\Units can be repeated and will be added together. This means that
        \\`1h1h` is equivalent to `2h`. This is confusing and should be avoided.
        \\A future update may disallow this.
        \\
        \\The maximum value is `584y 49w 23h 34m 33s 709ms 551µs 615ns`. Any
        \\value larger than this will be clamped to the maximum value.
        \\
        \\Available since 1.3.0
        ,
        .full_zh =
        \\如果启用了命令结束通知，这里控制命令至少运行多久才会发送通知。默认为五秒。
        \\
        \\时长写成一串数字加时间单位。数字和单位之间可以有空白。每组数字和单位加在一起，得到总时长。
        \\
        \\允许的时间单位如下：
        \\
        \\  * `y`：365 个 SI 日，即 8760 小时或 31536000 秒。不考虑闰年和闰秒。
        \\  * `d`：一个 SI 日，即 86400 秒。
        \\  * `h`：一小时，即 3600 秒。
        \\  * `m`：一分钟，即 60 秒。
        \\  * `s`：一秒。
        \\  * `ms`：一毫秒，即 0.001 秒。
        \\  * `us` 或 `µs`：一微秒，即 0.000001 秒。
        \\  * `ns`：一纳秒，即 0.000000001 秒。
        \\
        \\示例：
        \\  * `1h30m`
        \\  * `45s`
        \\
        \\单位可以重复，会被加在一起。也就是说 `1h1h` 等同于 `2h`。这样写容易混淆，应当避免。以后的版本可能不再允许。
        \\
        \\最大值是 `584y 49w 23h 34m 33s 709ms 551µs 615ns`。超过它的值会被限制为最大值。
        \\
        \\自 1.3.0 起可用
        ,
    },
    .{
        .key = .@"poltergeist-mcp",
        .en = "Let agents running in this terminal reach Poltergeist over a local socket, through the `polter +mcp` MCP server.",
        .zh = "让在此终端里运行的 agent 通过本地 socket，经 `polter +mcp` MCP 服务器连上 Poltergeist。",
        .full_en =
        \\Let agents running in this terminal reach Poltergeist over a local
        \\socket, through the `polter +mcp` MCP server.
        \\
        \\**On by default**, because this is what Polter is for. It was off while
        \\this was a patch on top of Ghostty, where the honest default was "behave
        \\as though none of it existed" -- but somebody who installs Polter and
        \\finds the conversations view dying on open, the supervisor unreachable
        \\and every agent tool absent has a terminal that is Ghostty with a
        \\different icon.
        \\
        \\**Opening the socket grants almost nothing on its own.** Until you make
        \\some terminal the supervisor, an agent holding a token can ask about
        \\itself, read a skill, and list the groups it is in -- which is none.
        \\Reading another terminal's screen, typing into one, and making groups
        \\all require the supervisor role, and only you can hand that out. The
        \\reach arrives with that decision, not with this switch.
        \\
        \\The socket is a unix socket in your state directory, never a network
        \\port. Each terminal gets its own token, placed in its environment as
        \\`GHOSTTY_POLTER_TOKEN`; an agent proves which terminal it is by holding
        \\that token and can never claim to be another one.
        \\
        \\Set it to `false` for a plain terminal that opens no socket at all.
        ,
        .full_zh =
        \\让在此终端里运行的 agent 通过本地 socket，经 `polter +mcp` MCP 服务器连上 Poltergeist。
        \\
        \\**默认开启**，因为 Polter 就是为此而做的。当它还是 Ghostty 上的一个补丁时，这项是关的，那时诚实的默认值是「装作这一切都不存在」。可是一个装了 Polter 的人，如果发现对话视图一打开就崩、总管连不上、agent 的工具一个都没有，那他手上的不过是换了个图标的 Ghostty。
        \\
        \\**单单打开 socket，几乎什么权限都不给。** 在你把某个终端设为总管之前，拿着 token 的 agent 只能问关于它自己的事、读 skill、列出它所在的群（一个也没有）。读别的终端的屏幕、往别的终端里打字、建群，都需要总管角色，而只有你能把这个角色交出去。能力是随那个决定而来的，不是随这个开关。
        \\
        \\socket 是你状态目录里的一个 unix socket，从来不是网络端口。每个终端有自己的 token，放在它的环境变量 `GHOSTTY_POLTER_TOKEN` 里；agent 靠持有这个 token 证明自己是哪个终端，永远不能冒充另一个。
        \\
        \\设为 `false`，就是一个完全不开 socket 的普通终端。
        ,
    },
    .{
        .key = .@"poltergeist-max-agents",
        .en = "How many agents may hold the socket at once.",
        .zh = "同时最多允许多少个 agent 占用该 socket。",
        .full_en =
        \\How many agents may hold the socket at once.
        \\
        \\One connection is one agent CLI running in one terminal, and it lasts as
        \\long as that CLI does. The cap exists because each connection is a thread
        \\and a pair of buffers, and because anything that can reach the socket
        \\could otherwise spawn threads until the process ran out.
        \\
        \\The number used to be a constant of 16 with a comment calling it
        \\generous. It was, for one person with a few terminals. It was measured
        \\full on an ordinary working day -- fifteen live agent CLIs, every one of
        \\them with a running parent, so nothing had leaked and nothing could be
        \\reclaimed -- and past that point *every new terminal* is refused, which
        \\is why this is a setting and not a larger constant. Whatever number is
        \\chosen here, somebody's day is the day they exceed it.
        \\
        \\Valid range is 1 to 256.
        ,
        .full_zh =
        \\同时最多允许多少个 agent 占用该 socket。
        \\
        \\一个连接就是在一个终端里运行的一个 agent CLI，它活多久，连接就占多久。设上限是因为每个连接是一个线程加一对缓冲区，而且任何能连上 socket 的东西，否则都可能不停地开线程，直到进程耗尽资源。
        \\
        \\这个数原来是常量 16，注释说它很宽裕。对一个人开几个终端来说，确实宽裕。可在一个普通的工作日里，它被实测用满了：十五个活着的 agent CLI，每个都有在运行的父进程，所以没有泄漏，也没有可以回收的。过了这个数，*每一个新终端*都会被拒绝，所以它成了一项设置，而不是改成一个更大的常量。不管这里选多大，总会有人的某一天超过它。
        \\
        \\有效范围是 1 到 256。
        ,
    },
    .{
        .key = .@"poltergeist-render-mailbox-capacity",
        .en = "Lower the renderer mailbox's capacity, so that a full mailbox can be reached deliberately. **Zero, the default, means the built-in bound.**",
        .zh = "调小渲染器邮箱的容量，以便能有意让邮箱装满。**默认值 0 表示使用内置上限。**",
        .full_en =
        \\Lower the renderer mailbox's capacity, so that a full mailbox can be
        \\reached deliberately. **Zero, the default, means the built-in bound.**
        \\
        \\🔴 **This is an instrument, not a tuning knob.** It exists so that a
        \\state can be produced on purpose for the purpose of watching what happens
        \\in it. There is no value of it that makes anything better, and the
        \\paragraph below says what it makes worse.
        \\
        \\## What it is for
        \\
        \\The renderer's mailbox holds 64 messages, and every producer has to decide
        \\what to do when it is full. Getting that decision wrong is a deadlock:
        \\task 443 was the UI thread waiting, with no bound, for room in a mailbox
        \\that only the renderer could empty, while the renderer had stopped being
        \\woken. That is fixed -- but the fault that used to fill the mailbox was
        \\fixed too, so **there is no longer any way to reach a full mailbox by
        \\accident**, and a test machine cannot tell "the full-mailbox handling
        \\works" from "the mailbox never filled". Both produce no evidence at all.
        \\
        \\Setting this to a small number was meant to make the mailbox fill in the
        \\ordinary course of events, on exactly the code paths a shipping build
        \\runs.
        \\
        \\## 🔴 On a real machine it does not do that
        \\
        \\**Measured, six ways, all negative.** Ceilings of 1 and 2, against a
        \\steady output probe, against burst production, and against a tight
        \\non-modal resize loop; a seventh arrangement -- dragging the window frame
        \\by hand, which is modal -- ⚠️ **could not be carried out at all, which is
        \\not the same as a negative result** and is recorded separately for that
        \\reason.
        \\
        \\**Why it fails, and the reason is structural rather than a matter of
        \\picking a smaller number:** every delivery wakes the consumer. So the
        \\faster messages are produced, the faster they are drained -- production
        \\and consumption rise together, and the queue does not accumulate. **It
        \\fills only while the consumer is prevented from running**, and being
        \\prevented from running is precisely the defect that has since been fixed.
        \\⇒ The state this setting was added to reproduce is, on a healthy build,
        \\reachable by nothing this project has found.
        \\
        \\## Where it is still worth having
        \\
        \\**In the tests, where the consumer can simply be left out.** Three checks
        \\in `blocking_queue.zig` and `renderer/Thread.zig` turn on it -- that the
        \\default ceiling holds exactly what it always held, that a lowered one
        \\makes the queue full early on the ordinary path, and that a caller then
        \\reaches the branch which gives up and reports. Two mutation cells have
        \\nothing to bite on without it either.
        \\
        \\⚠️ **So it is not useless; its use is not on a real machine.** Those are
        \\different sentences and only the second one is a limitation.
        \\
        \\⚠️ **And six negatives are six negatives.** If somebody finds an
        \\arrangement that does fill it, none of the above was wrong -- it was
        \\six specific attempts, and the list of what was tried is above so that a
        \\seventh does not have to repeat them.
        \\
        \\## ⚠️ Why turning it down is not a tuning knob
        \\
        \\It does not make anything faster and it is not a memory saving -- the
        \\storage is a fixed array either way, so a lower ceiling frees nothing.
        \\What it does is make delivery **fail**: past the ceiling, messages to the
        \\renderer are dropped after a wait, and a dropped message is not a
        \\slow-down but a state the renderer never hears about. A dropped focus
        \\change leaves the cursor blinking as though the window were still focused,
        \\and nothing corrects it, because the renderer keeps that state and only
        \\learns of changes from the message it just lost.
        \\
        \\**Anything above about a dozen is indistinguishable from off in ordinary
        \\use** -- which is another way of saying that a value low enough to be
        \\useful is low enough to be visible.
        \\
        \\## Why there is no floor on it
        \\
        \\**This section used to say that a ceiling of one or two was the only range
        \\in which the queue actually fills.** That was written before the six
        \\measurements above; 1 and 2 were among the settings tried, and neither
        \\filled it. The sentence is left named here rather than quietly deleted
        \\because it was the stated reason for having no floor, and a reason that
        \\has been replaced should say so.
        \\
        \\**The conclusion is unchanged and the reason is now this**: a floor would
        \\remove the only settings that have any chance at all, on an instrument
        \\that is already not reaching its target. It would not make the setting
        \\safer, it would make it certainly inert. The protection against somebody
        \\turning it down and then reporting the consequences as a bug is instead
        \\that turning it on **says so in the log at startup**, so such a report is
        \\traceable to it in one line.
        \\
        \\Valid range is 0 (off) to 64.
        ,
        .full_zh =
        \\调小渲染器邮箱的容量，以便能有意让邮箱装满。**默认值 0 表示使用内置上限。**
        \\
        \\🔴 **这是一件测量工具，不是调优旋钮。** 它的存在，是为了能故意造出一个状态，好观察在那个状态下会发生什么。它没有哪个值能让任何东西变好，下面一段说的是它会让什么变坏。
        \\
        \\## 它是做什么用的
        \\
        \\渲染器的邮箱能放 64 条消息，每个往里放消息的一方都得决定邮箱满了怎么办。这个决定做错了就是死锁：task 443 就是界面线程无限期地等邮箱腾出空间，而能清空邮箱的只有渲染器，渲染器那时却已经不再被唤醒。这个问题已经修了，可当初把邮箱塞满的那个毛病也一起修了，所以**再也没有办法意外地让邮箱装满**，测试机分不出「邮箱满了的处理是对的」和「邮箱从来没满过」。两者都拿不出任何证据。
        \\
        \\把它设成一个小数，本意是让邮箱在正常运行中就装满，而且走的正是正式发布版会走的代码路径。
        \\
        \\## 🔴 在真机上它做不到
        \\
        \\**实测了六种方式，全是否定的。** 上限设为 1 和 2，分别对着稳定输出的探针、成批的输出，以及一个紧密的非模态缩放循环；第七种安排是用手拖窗口边框（那是模态的），⚠️ **根本没能做成，这和否定的结果不是一回事**，所以单独记下。
        \\
        \\**为什么做不到，而且原因是结构上的，不是选个更小的数就能解决：** 每次投递都会唤醒消费方。所以消息产生得越快，被取走得也越快，生产和消费一起涨，队列不会积压。**只有消费方被拦着不能运行时，它才会满**，而被拦着不能运行，恰恰就是后来修掉的那个毛病。⇒ 这项设置原本要重现的那个状态，在健康的版本上，这个项目还没找到任何办法能达到。
        \\
        \\## 它在哪里仍然值得留着
        \\
        \\**在测试里，消费方可以干脆不放进去。** `blocking_queue.zig` 和 `renderer/Thread.zig` 里有三项检查用到它：默认上限装的正好和以前一样多；调低以后，队列会在普通路径上提前装满；调用方随后会走到放弃并报告的那个分支。还有两个变异格，没有它也无从下手。
        \\
        \\⚠️ **所以它不是没用；只是它的用处不在真机上。** 这是两句不同的话，只有后一句是限制。
        \\
        \\⚠️ **六个否定也只是六个否定。** 如果有人找到了能把它装满的安排，上面说的都没有错：那只是六次具体的尝试，上面列出了试过什么，好让第七次不必重复。
        \\
        \\## ⚠️ 为什么把它调低不是调优旋钮
        \\
        \\它不会让任何东西变快，也不省内存：存储无论如何都是一个固定大小的数组，上限调低也腾不出任何东西。它做的是让投递**失败**：超过上限后，发给渲染器的消息在等待之后会被丢掉，而一条被丢掉的消息不是变慢，而是渲染器永远不知道的一个状态。丢掉一次焦点变化，光标就会像窗口仍有焦点那样一直闪，而且没有任何东西去纠正它，因为渲染器自己保存着那个状态，只能从刚刚丢掉的那条消息里得知变化。
        \\
        \\**大约十几以上的值，在普通使用中和关掉没有区别**，换句话说，低到有用的值，也低到看得出来。
        \\
        \\## 为什么它没有下限
        \\
        \\**这一节以前说，上限 1 或 2 是队列真正会装满的唯一范围。** 那是在上面六次测量之前写的；1 和 2 都在试过的设置里，哪个都没装满。这句话在这里点名留着，而不是悄悄删掉，因为它曾是「不设下限」的理由，而一个被替换掉的理由应该说明它被替换了。
        \\
        \\**结论不变，理由现在是这样**：设下限会去掉唯一还有一点机会的那几个值，而这件工具本来就没打中目标。那样做不会让这项设置更安全，只会让它肯定不起作用。防止有人把它调低、然后把后果当成缺陷来报的办法是另一个：一打开它，**启动时就会在日志里说明**，这样的报告用一行就能追到它头上。
        \\
        \\有效范围是 0（关闭）到 64。
        ,
    },
    .{
        .key = .@"poltergeist-register-mcp",
        .en = "Register Polter as an MCP server with Claude Code, so that agents in any directory can reach it.",
        .zh = "把 Polter 注册为 Claude Code 的 MCP 服务器，这样任何目录里的 agent 都能连上它。",
        .full_en =
        \\Register Polter as an MCP server with Claude Code, so that agents in
        \\any directory can reach it.
        \\
        \\Polter puts a socket path and a token in every terminal's environment,
        \\which is what an agent needs to *reach* it -- but an MCP client only
        \\loads servers it has been configured with, so without this an agent
        \\has both and no tools. Registration is user-scoped, so it applies
        \\wherever you start one.
        \\
        \\Checked at every start and rewritten only when it does not point at
        \\this build: that file is Claude Code's own, and rewriting it for no
        \\reason is asking for the one race that eats somebody's settings.
        \\
        \\Done by running `claude mcp`, so it does nothing when Claude Code is
        \\not installed. Set it to `false` to manage the registration yourself.
        ,
        .full_zh =
        \\把 Polter 注册为 Claude Code 的 MCP 服务器，这样任何目录里的 agent 都能连上它。
        \\
        \\Polter 会在每个终端的环境变量里放一个 socket 路径和一个 token，这是 agent *连上*它所需要的；但 MCP 客户端只加载配置过的服务器，所以没有这一步，agent 两样都有，却一个工具都没有。注册是用户级的，所以你在哪里启动 agent 都适用。
        \\
        \\每次启动都会检查，只有在它没指向当前这个版本时才重写：那个文件是 Claude Code 自己的，无缘无故去重写它，就是在招惹那种会吃掉别人设置的竞态。
        \\
        \\做法是运行 `claude mcp`，所以没装 Claude Code 时它什么也不做。设为 `false` 就由你自己管理注册。
        ,
    },
    .{
        .key = .@"poltergeist-watch",
        .en = "Watch this terminal for quiescence.",
        .zh = "监视此终端是否静止。",
        .full_en =
        \\Watch this terminal for quiescence.
        \\
        \\This is the sensing half of Poltergeist. When enabled, Ghostty samples
        \\the visible screen periodically and measures how long it has gone
        \\unchanged. It does not read, interpret, or act on what is on the screen.
        \\
        \\Ghostty never decides what a still screen *means* -- whether the program
        \\is thinking, waiting, finished, or wedged. That judgement belongs to the
        \\supervising agent, which looks at the screen itself.
        \\
        \\The default is `false`: nothing is watched unless you ask for it.
        ,
        .full_zh =
        \\监视此终端是否静止。
        \\
        \\这是 Poltergeist 负责感知的那一半。启用后，Ghostty 会定期采样可见的屏幕，测量它多久没有变化。它不读、不解释，也不对屏幕上的内容做任何动作。
        \\
        \\一块静止的屏幕*意味着*什么（程序在思考、在等待、已经完成，还是卡住了），Ghostty 从不判断。那个判断属于负责监督的 agent，它会自己去看屏幕。
        \\
        \\默认是 `false`：除非你要求，否则什么都不监视。
        ,
    },
    .{
        .key = .@"poltergeist-quiescence-after",
        .en = "How long the visible screen must go unchanged before this terminal is considered quiescent.",
        .zh = "屏幕上可见内容保持不变多久后，才认为该终端静止。",
        .full_en =
        \\How long the visible screen must go unchanged before this terminal is
        \\considered quiescent.
        \\
        \\Only has an effect when `poltergeist-watch` is enabled.
        \\
        \\Set this to how long you would wait before glancing at the terminal
        \\yourself. Too short and a program that pauses to think looks stuck; too
        \\long and a genuinely finished terminal sits idle. A screen that is being
        \\redrawn without changing -- a spinner, for instance -- still counts as
        \\unchanged, which is deliberate: the redraw tells you the program is
        \\alive, not that it is making progress.
        \\
        \\## A short value and a closed laptop lid
        \\
        \\A machine asleep does not stop entirely. macOS wakes it for a few tens of
        \\seconds every quarter of an hour or so to do maintenance, and Ghostty is
        \\running during those windows. Sampling knows about this: a gap far larger
        \\than the sampling interval is treated as a window nobody was watching the
        \\screen in, so it is not counted as stillness and nothing is reported.
        \\
        \\**But a wake window is long enough to be quiescent in its own right, if
        \\you set this short enough.** At the default of three minutes it is not --
        \\a wake ends long before the terminal earns a report. Set this to less
        \\than about a minute and each wake becomes its own little idle period, and
        \\a laptop left shut overnight can report itself once per wake. Nothing
        \\below can prevent that: it is this setting asking for reports that fast.
        ,
        .full_zh =
        \\屏幕上可见内容保持不变多久后，才认为该终端静止。
        \\
        \\只在启用 `poltergeist-watch` 时有效。
        \\
        \\把它设成你自己会等多久才去瞄一眼那个终端。太短，停下来思考的程序看起来像卡住了；太长，真正做完的终端会闲着没人管。一块在重绘、内容却不变的屏幕（比如转圈的动画）仍然算没有变化，这是有意的：重绘说明程序还活着，不说明它有进展。
        \\
        \\## 一个很短的值，加上合上的笔记本盖子
        \\
        \\机器睡眠时并不完全停下。macOS 大约每一刻钟就会把它唤醒几十秒做维护，那段时间 Ghostty 也在运行。采样知道这件事：一段远大于采样间隔的空白，会被当作没人看着屏幕的一段时间，所以不算静止，也不报告。
        \\
        \\**但如果你把这项设得够短，一次唤醒的时长本身就足以构成静止。** 默认三分钟时不会：唤醒早在终端够格被报告之前就结束了。把它设得比一分钟左右还短，每次唤醒都会成为一小段空闲，一台合着盖子放了一整夜的笔记本，每醒一次就可能报告一次。下面没有任何东西能防止这一点：这是这项设置自己要求报告得那么快。
        ,
    },
    .{
        .key = .@"poltergeist-quiescence-repeat",
        .en = "How long to wait before reporting a terminal that is *still* quiescent.",
        .zh = "对仍然静止的终端，隔多久再报告一次。",
        .full_en =
        \\How long to wait before reporting a terminal that is *still* quiescent.
        \\
        \\Only has an effect when `poltergeist-watch` is enabled.
        \\
        \\Without this, a terminal parked overnight would report itself on every
        \\sample. The first report fires at `poltergeist-quiescence-after`; this
        \\controls every one after that.
        ,
        .full_zh =
        \\对仍然静止的终端，隔多久再报告一次。
        \\
        \\只在启用 `poltergeist-watch` 时有效。
        \\
        \\没有它，一个停放了一整夜的终端每次采样都会报告自己。第一次报告在 `poltergeist-quiescence-after` 时发出；这一项控制之后的每一次。
        ,
    },
    .{
        .key = .@"poltergeist-notice-interval",
        .en = "How often the supervisor may be interrupted with what it has not seen.",
        .zh = "总管最短隔多久可被打断一次，告知它还没看到的内容。",
        .full_en =
        \\How often the supervisor may be interrupted with what it has not seen.
        \\
        \\Reports do not go to the supervisor as they happen. They collect, one
        \\entry per terminal, and are handed over on this interval as a single
        \\line naming everything that is waiting. Reading clears them.
        \\
        \\This is what bounds the interruptions: the per-terminal settings above
        \\cannot, because each watched terminal keeps its own clock and ten of
        \\them make ten times the noise while the supervisor remains one terminal
        \\with one screen. Raise it if the supervisor is being interrupted more
        \\often than the work warrants; lower it if you want to hear sooner.
        \\
        \\The supervisor can always look of its own accord with the `notices`
        \\tool, which this does not delay -- choosing to look is not an
        \\interruption.
        ,
        .full_zh =
        \\总管最短隔多久可被打断一次，告知它还没看到的内容。
        \\
        \\报告不是一发生就交给总管。它们会先攒起来，每个终端一条，按这个间隔合成一行交过去，列出所有在等的内容。读过以后就清掉。
        \\
        \\打断的次数靠这一项来限制：上面那些针对单个终端的设置做不到，因为每个受监视的终端各有各的时钟，十个终端就是十倍的噪音，而总管始终只是一个终端、一块屏幕。如果总管被打断得比工作需要的还频繁，就调大；想早点听到，就调小。
        \\
        \\总管随时可以自己用 `notices` 工具去看，这一项不会让它变慢：主动去看不算打断。
        ,
    },
    .{
        .key = .@"poltergeist-task-idle-after",
        .en = "How long a task may go untouched before it is worth a line.",
        .zh = "任务无人动过多久后，值得提一句。",
        .full_en =
        \\How long a task may go untouched before it is worth a line.
        \\
        \\Nothing has happened to it -- no assignment, no progress report, no
        \\close -- for this long, and its number rides out with the supervisor's
        \\next hand-over, in the same line and on the same clock as the quiet
        \\screens. Only for a group that has a supervisor; a group nobody has
        \\taken up has nobody to tell.
        \\
        \\**This is a mark, not a verdict, and the difference is the whole
        \\point.** A task open for two days may be stalled, or it may be a
        \\standing lease that is *meant* to stay open -- the terminal holding a
        \\machine nobody else may touch is a task by design. Nothing here can
        \\tell those apart and nothing here tries: the line says how long, and
        \\the supervisor says what that means. The same rule
        \\`poltergeist-quiescence-after` keeps about a screen.
        \\
        \\Twelve hours by default: long enough that ordinary work does not trip
        \\it, short enough to catch a night that went wrong at two in the
        \\morning. Set it to zero to say nothing about tasks at all.
        ,
        .full_zh =
        \\任务无人动过多久后，值得提一句。
        \\
        \\这么长时间里它什么都没发生：没有派单、没有进度汇报、没有关单。于是它的编号会随总管下一次的汇总一起送出，和静止的屏幕在同一行、按同一个时钟。只针对有总管的群；没人接手的群，也就没有可以告诉的人。
        \\
        \\**这是一个标记，不是一个判决，两者的区别正是要点所在。** 一个开了两天的任务，可能卡住了，也可能是一份*本来就该*一直开着的长期租约：占着一台别人都不许碰的机器的那个终端，按设计就是一个任务。这里没有任何东西能分清两者，也不去尝试：那一行只说过了多久，那意味着什么由总管来说。这和 `poltergeist-quiescence-after` 对屏幕守的是同一条规矩。
        \\
        \\默认十二小时：长到普通工作不会触发，短到能抓住凌晨两点出了岔子的一夜。设为零就完全不提任务。
        ,
    },
    .{
        .key = .@"poltergeist-worker-nudge-after",
        .en = "How long a worker's screen may be still before it is reminded to report.",
        .zh = "worker 的屏幕静止多久后，提醒它汇报。",
        .full_en =
        \\How long a worker's screen may be still before it is reminded to report.
        \\
        \\A terminal holding open work whose screen has stopped is told once, in
        \\its own input box: it is still holding #93, and if it has finished or is
        \\stuck, that is what `task_progress` is for.
        \\
        \\**This exists because printing is not reporting.** A worker that
        \\finishes writes its account to its own screen, and nothing on that
        \\screen reaches anybody -- the supervisor sees only that the terminal
        \\went quiet, and has to go and look to find out whether that means done
        \\or dead. On the record this was written against, 71 tasks produced 15
        \\`done` reports and one `blocked`, so the instruction in the skill is
        \\demonstrably not enough on its own. This puts it in front of the worker
        \\at the one moment it is about to be needed.
        \\
        \\**Longer than `poltergeist-quiescence-after`, deliberately.** That one
        \\decides when to tell the supervisor, which costs the supervisor a line;
        \\this one types into a worker that may be thinking, which costs it a
        \\turn. Once per task, and again only if the task is handed out afresh --
        \\a reminder that repeats is a reminder that gets ignored, and worse, one
        \\that competes with the supervisor's own instructions.
        \\
        \\Set it to zero to switch it off. Only has an effect when
        \\`poltergeist-watch` is enabled, since nothing measures a screen
        \\otherwise.
        ,
        .full_zh =
        \\worker 的屏幕静止多久后，提醒它汇报。
        \\
        \\一个手上有未完成工作、屏幕又停了的终端，会在它自己的输入框里被提醒一次：它还拿着 #93，如果已经做完或卡住了，那就是 `task_progress` 的用处。
        \\
        \\**之所以有这一项，是因为打印不等于汇报。** 一个做完的 worker 把它的交代写在自己的屏幕上，而那块屏幕上的东西谁也看不到：总管只看见那个终端安静了，得自己去看，才知道那意味着做完了还是死了。在写这一项时依据的记录里，71 个任务只产生了 15 次 `done` 汇报和一次 `blocked`，可见光靠 skill 里的说明显然不够。这一项把提醒放到 worker 面前，恰好在它即将需要的那一刻。
        \\
        \\**故意比 `poltergeist-quiescence-after` 长。** 那一项决定什么时候告诉总管，代价是总管的一行；这一项是往一个可能正在思考的 worker 里打字，代价是它的一轮。每个任务一次，只有任务重新派出时才会再来：一再重复的提醒是会被无视的提醒，更糟的是，它还会和总管自己的指令抢位置。
        \\
        \\设为零就关掉。只在启用 `poltergeist-watch` 时有效，因为否则没有东西去测量屏幕。
        ,
    },
    .{
        .key = .@"poltergeist-group-quiet-after",
        .en = "How long a group may be silent before it is worth a line.",
        .zh = "群沉默多久后，值得提一句。",
        .full_en =
        \\How long a group may be silent before it is worth a line.
        \\
        \\The same channel and the same rule as the setting above, about the
        \\conversation rather than the panel: nobody has said anything in this
        \\group for this long. A group whose work is finished is silent and is
        \\supposed to be, which is exactly why this reports the duration and
        \\stops there.
        \\
        \\Set it to zero to say nothing about silence.
        ,
        .full_zh =
        \\群沉默多久后，值得提一句。
        \\
        \\和上面那项设置用同一个渠道、同一条规矩，只是说的是对话而不是面板：这个群里这么久没人说过话。一个工作已经结束的群是沉默的，而且本该如此，所以这一项只报时长，到此为止。
        \\
        \\设为零就完全不提沉默。
        ,
    },
    .{
        .key = .@"poltergeist-calls-silent-after",
        .en = "How long a watched terminal may go without calling a Polter tool before that is worth a line.",
        .zh = "受监视的终端没调用 Polter 工具多久后，值得提一句。",
        .full_en =
        \\How long a watched terminal may go without calling a Polter tool before
        \\that is worth a line.
        \\
        \\**A second clock, beside the screen's.** `poltergeist-quiescence-after`
        \\measures whether the screen has stopped changing, and a screen can keep
        \\changing after the work has stopped: an agent whose CLI hit a network
        \\error and sits in a retry loop redraws its countdown for ever, and reads
        \\as busy. An agent that is working calls tools. So this counts from the
        \\last one, and the line it produces -- `0x… no tool call 22m (screen
        \\changed 3s ago)` -- rides out in the supervisor's box, in the same line
        \\and on the same clock as the quiet reports (`poltergeist-notice-interval`),
        \\and again each further time this much has passed.
        \\
        \\**A supervisor's own silence is shown on its tab**: the flag goes
        \\hollow. Its box is the one place it could not be told, since a stuck
        \\supervisor is exactly the one that does not read it.
        \\
        \\**Arithmetic, not a verdict**, like every other line here. A worker
        \\waiting on a permission prompt, or sitting through a long build, calls
        \\nothing and is fine. The line says how long; reading the terminal says
        \\why.
        \\
        \\Only counted from the first call: a terminal whose agent has never
        \\called a tool -- a plain shell, or an agent that never started -- is
        \\never reported by this. Traffic the sidecar makes on its own account is
        \\not a call; see `rpc.isAgentCall`.
        \\
        \\Fifteen minutes by default. Set it to zero to switch it off, both the
        \\line and the tab.
        ,
        .full_zh =
        \\受监视的终端没调用 Polter 工具多久后，值得提一句。
        \\
        \\**在屏幕的时钟旁边，另一个时钟。** `poltergeist-quiescence-after` 测的是屏幕有没有停止变化，可工作停了以后屏幕仍然可能在变：一个 CLI 遇到网络错误、陷在重试循环里的 agent，会一直重绘它的倒计时，看起来很忙。一个在干活的 agent 会调用工具。所以这一项从最后一次调用算起，它产生的那一行（`0x… no tool call 22m (screen changed 3s ago)`）会送进总管的信箱，和静止报告在同一行、按同一个时钟（`poltergeist-notice-interval`），之后每再过这么久就再送一次。
        \\
        \\**总管自己的沉默显示在它的标签上**：旗子会变成空心的。信箱是唯一没法告诉它的地方，因为一个卡住的总管恰恰就是不读信箱的那一个。
        \\
        \\**只是算术，不是判决**，和这里的其他每一行一样。一个在等权限提示的 worker，或者在等一个很长的构建，什么都不调用，也没有问题。那一行只说过了多久；为什么，要读那个终端才知道。
        \\
        \\只从第一次调用开始算：一个它的 agent 从没调用过工具的终端（普通的 shell，或者一个根本没起来的 agent），永远不会被这一项报告。sidecar 自己发起的通信不算调用；见 `rpc.isAgentCall`。
        \\
        \\默认十五分钟。设为零就关掉，那一行和标签上的标记都关掉。
        ,
    },
    .{
        .key = .@"poltergeist-silence-remind-after",
        .en = "How long a group's supervisor may go with nothing heard from its terminal -- no line typed into it by Polter (a quiet report, a group mention, an alarm) and no Polter tool called by the agent in it (`rpc.isAgentCall`: a CLI's own hooks and the sidecar's traffic are not calls) -- while its group has tasks not closed or cancelled, before it is reminded to look at the whole of it (task 2148). The reminder then repeats every this long while the silence lasts. Not while it has an alarm set: it said when it wants to be woken. Time the machine is asleep is not counted. `0` switches the reminder off.",
        .zh = "群的总管在它的群还有没关闭、没取消的任务时，可以多久听不到自己终端的任何动静——Polter 没往里打过一行（静止报告、群里点名、闹钟），里面的 agent 也没调用过 Polter 工具（`rpc.isAgentCall`：CLI 自己的 hook 和边车自己的流量不算调用）——之后提醒它把全局看一遍（任务 2148）。沉默持续时，每隔这么久再提醒一次。设了闹钟时不提醒：它已经说了想什么时候被叫醒。机器睡眠的时间不算。`0` 关掉提醒。",
        .full_en =
        \\How long a group's supervisor may go with nothing heard from its terminal
        \\-- no line typed into it by Polter (a quiet report, a group mention, an
        \\alarm) and no Polter tool called by the agent in it (`rpc.isAgentCall`:
        \\a CLI's own hooks and the sidecar's traffic are not calls) -- while its
        \\group has tasks not closed or cancelled, before it is reminded to look
        \\at the whole of it
        \\(task 2148). The reminder then repeats every this long while the silence
        \\lasts. Not while it has an alarm set: it said when it wants to be woken.
        \\Time the machine is asleep is not counted. `0` switches the reminder off.
        ,
        .full_zh =
        \\群的总管在它的群还有没关闭、没取消的任务时，可以多久听不到自己终端的任何动静——Polter 没往里打过一行（静止报告、群里点名、闹钟），里面的 agent 也没调用过 Polter 工具（`rpc.isAgentCall`：CLI 自己的 hook 和边车自己的流量不算调用）——之后提醒它把全局看一遍（任务 2148）。沉默持续时，每隔这么久再提醒一次。设了闹钟时不提醒：它已经说了想什么时候被叫醒。机器睡眠的时间不算。`0` 关掉提醒。
        ,
    },
    .{
        .key = .@"poltergeist-stall-warn-after",
        .en = "How long Polter's app thread may spend on one thing before it is written in the log.",
        .zh = "Polter 的应用线程在一件事上停留多久后，会写进日志。",
        .full_en =
        \\How long Polter's app thread may spend on one thing before it is written
        \\in the log.
        \\
        \\The app thread is the one every terminal's events, every agent's tool
        \\call and the window itself go through; while one thing holds it, nothing
        \\else is answered. When that has lasted this long, another thread writes a
        \\warning naming what it is -- which kind of message and, for an agent's
        \\tool call, the tool and the terminal it came from -- and, when it ends,
        \\a second line with how long it took. Once per stall, however long.
        \\
        \\Watching costs the app thread nothing it would notice: no lock and no
        \\log of its own. Two seconds by default; zero switches it off.
        ,
        .full_zh =
        \\Polter 的应用线程在一件事上停留多久后，会写进日志。
        \\
        \\每个终端的事件、每个 agent 的工具调用，还有窗口本身，都要经过应用线程；某件事占着它的时候，别的都得不到回应。持续这么久以后，另一个线程会写一条警告，说明是什么：哪一类消息，如果是 agent 的工具调用，还有是哪个工具、来自哪个终端；它结束时再写一行，说明用了多久。每次停顿只写一次，不管多久。
        \\
        \\监视对应用线程来说几乎没有代价：不加锁，也不写它自己的日志。默认两秒；设为零就关掉。
        ,
    },
    .{
        .key = .@"poltergeist-compact-after",
        .en = "How much uncompacted conversation a group may carry before the supervisor is reminded to tidy it.",
        .zh = "群里积累多少未整理的对话后，提醒总管整理。",
        .full_en =
        \\How much uncompacted conversation a group may carry before the
        \\supervisor is reminded to tidy it.
        \\
        \\`group_compact` replaces a stretch of a group's messages with one line
        \\the supervisor writes. **Nothing else asks for that to happen**: it is
        \\the one piece of housekeeping here with no clock behind it, and a
        \\supervisor with a night's work in front of it does not think of it.
        \\Meanwhile the cost is paid by every member — a `group_read` carries the
        \\whole thing, and past 96KB a single read cannot even fit in one reply.
        \\
        \\Measured over the text a compaction has *not* already replaced, so the
        \\number falls when one happens and climbs again afterwards. The reminder
        \\rides out with the supervisor's next hand-over, in the same line and on
        \\the same clock as everything else it is told; see
        \\`poltergeist-notice-interval`.
        \\
        \\**It says the size and stops there.** Whether a conversation is worth
        \\compacting depends on what is in it -- a night of one-line reports and
        \\a night of pasted stack traces are the same number of bytes and not the
        \\same decision. Set it to zero to say nothing about size.
        ,
        .full_zh =
        \\群里积累多少未整理的对话后，提醒总管整理。
        \\
        \\`group_compact` 用总管写的一行话，替换掉群里的一段消息。**没有别的东西会要求这件事发生**：这是这里唯一一项背后没有时钟的整理工作，而一个面前摆着一整夜工作的总管不会想到它。与此同时，代价由每个成员来付：一次 `group_read` 会带上全部内容，超过 96KB 时，一次读取甚至装不进一个回复。
        \\
        \\按还*没有*被整理替换过的文字来算，所以整理一次，这个数就降下来，之后再涨上去。提醒会随总管下一次的汇总一起送出，和它被告知的其他所有内容在同一行、按同一个时钟；见 `poltergeist-notice-interval`。
        \\
        \\**它只报大小，到此为止。** 一段对话值不值得整理，取决于里面是什么：一夜的单行汇报和一夜贴进来的堆栈信息，字节数可以一样，要做的决定却不一样。设为零就完全不提大小。
        ,
    },
    .{
        .key = .@"poltergeist-supervisor-stand-down",
        .en = "Whether a supervisor may take itself off duty.",
        .zh = "总管是否可以自己下岗。",
        .full_en =
        \\Whether a supervisor may take itself off duty.
        \\
        \\A supervisor is woken on `poltergeist-notice-interval` for as long as it
        \\is one. When the work it was minding is finished that wake-up costs
        \\context and buys nothing, every interval, all night -- so by default a
        \\supervisor that has finished can say so and stop being one.
        \\
        \\It cannot do that as a shortcut. Standing down is refused while it still
        \\minds any terminal, so it has to let each one go first, deliberately and
        \\one at a time; only then may it step down itself.
        \\
        \\It may put itself forward again afterwards, with `become_supervisor`.
        \\What standing down guards against is a supervisor quietly carrying on
        \\collecting an empty box all night, and coming back is the opposite of
        \\quietly: it is one deliberate act that leaves a record in the group.
        \\(A terminal somebody else is watching may never do this, whether or not
        \\it once stood down -- it already has a supervisor, and text arriving in
        \\it must not be able to rearrange who may reach whom.)
        \\
        \\Set this to false if being a supervisor should be a standing
        \\instruction that only you can withdraw, the way holding a terminal to
        \\its work is. The cost of false is the wake-ups continuing after there
        \\is anything to wake up for; the cost of true is a supervisor that
        \\decides too early that the night is over, and stops watching while you
        \\sleep.
        ,
        .full_zh =
        \\总管是否可以自己下岗。
        \\
        \\只要还是总管，它就会按 `poltergeist-notice-interval` 被唤醒。它看管的工作完成以后，这种唤醒每个间隔都要花掉上下文，却什么也换不来，整夜如此。所以默认情况下，做完了的总管可以说一声，然后不再当总管。
        \\
        \\它不能走捷径。只要它还看管着任何一个终端，下岗就会被拒绝，所以它得先逐个、有意地放掉每一个，然后才能自己下岗。
        \\
        \\之后它可以用 `become_supervisor` 再次自荐。下岗要防的，是一个总管悄悄地整夜收着一个空信箱；而回来恰恰和悄悄相反：那是一个有意的动作，会在群里留下记录。（一个正被别人看着的终端永远不能这样做，不管它是不是曾经下过岗：它已经有总管了，而进到它里面的文字不能有能力改变谁可以触及谁。）
        \\
        \\如果你希望当总管是一条只有你能收回的长期指令，就像把一个终端定在它的工作上那样，就把它设为 false。设为 false 的代价是，已经没有事可以叫醒它了，唤醒还在继续；设为 true 的代价是，一个总管可能过早认定这一夜结束了，在你睡觉时停止看管。
        ,
    },
    .{
        .key = .@"poltergeist-may-authorise",
        .en = "Whether a supervisor may answer a permission prompt in another terminal -- the `terminal_answer_prompt` tool and the keys that take an option in one -- when you have not said otherwise for that terminal.",
        .zh = "在你没有为某个终端另行设定时，总管是否可以回答另一个终端里的权限提示——即 `terminal_answer_prompt` 工具，以及选中提示里某个选项的按键。",
        .full_en =
        \\Whether a supervisor may answer a permission prompt in another terminal
        \\-- the `terminal_answer_prompt` tool and the keys that take an option in
        \\one -- when you have not said otherwise for that terminal.
        \\
        \\On by default. A worker that stops on "Do you want to proceed?" is then
        \\the supervisor's to deal with: it answers what is plainly part of the
        \\work and brings the rest to you, so you are seldom sent to a worker's
        \\terminal at all.
        \\
        \\**What that opens, said plainly.** Any terminal you have made a
        \\supervisor can take either answer in the prompt of any terminal that is
        \\not shielded, including "Yes, and don't ask again" -- which writes a
        \\standing permission into that directory, so every agent that runs there
        \\afterwards stops being asked. Polter cannot tell which of the two was
        \\pressed; it sends keys.
        \\
        \\Three ways to say no, narrowest first: the terminal's own menu item
        \\("Let a Supervisor Answer This Terminal's Prompts"), which lasts as long
        \\as that terminal does; the shield ("Keep Agents Out of This Terminal"),
        \\which keeps every tool out of it; and setting this to `false`, which
        \\makes off the starting point for every terminal again and is the one
        \\that is still in force after a restart. With this `false` the menu item
        \\switches a single terminal on.
        \\
        \\Only you can change any of the three: no tool, key binding or command
        \\palette entry reaches them.
        ,
        .full_zh =
        \\在你没有为某个终端另行设定时，总管是否可以回答另一个终端里的权限提示——即 `terminal_answer_prompt` 工具，以及选中提示里某个选项的按键。
        \\
        \\默认开启。这样一个停在“Do you want to proceed?”上的 worker 就归总管处理：明显属于工作一部分的，它会回答；其余的交给你。所以你很少需要亲自去 worker 的终端。
        \\
        \\**这会放开什么，明说如下。** 任何被你设为总管的终端，都可以在任何未被屏蔽的终端的提示里选任一答案，包括 “Yes, and don't ask again”：这会在那个目录里写下一条长期许可，之后在那里运行的每个 agent 都不再被问。Polter 分不出按的是两者中的哪一个；它只是发送按键。
        \\
        \\有三种方式说不，从窄到宽：终端自己的菜单项（“Let a Supervisor Answer This Terminal's Prompts”），效力和那个终端一样长；屏蔽（“Keep Agents Out of This Terminal”），把所有工具都挡在外面；以及把这项设为 `false`，让每个终端重新从关闭开始，而且是重启后仍然生效的那一种。这项为 `false` 时，那个菜单项用来为单个终端打开。
        \\
        \\三者都只有你能改：没有任何工具、快捷键或命令面板项能触及它们。
        ,
    },
    .{
        .key = .@"poltergeist-pane-frames",
        .en = "Draw each pane of a split with the frame of what is in it.",
        .zh = "给分屏的每个窗格画上与其内容相符的边框。",
        .full_en =
        \\Draw each pane of a split with the frame of what is in it.
        \\
        \\With this on, a tab that is split draws every pane as a card with a
        \\title: a supervisor's pane has a thick border whose top is its title
        \\bar, a worker's has a thin line round it and a title band, and an
        \\ordinary terminal's has its title written on its own background. The
        \\title bar says which terminal it is and, for an agent, what it is doing
        \\just now. A tab with a single ordinary terminal in it is drawn as it
        \\always was; a supervisor or a worker wears its frame even alone. The
        \\quick terminal is never framed.
        \\
        \\A title takes room from the terminal under it, so a framed pane is two
        \\rows or so shorter than it would be. Set this to `false` to draw splits
        \\the way they were before there were frames.
        \\
        \\On macOS and Windows. On Windows the terminal itself keeps square
        \\corners, so a worker's and an ordinary terminal's frame is round at the
        \\top only, and no frame has a shadow.
        ,
        .full_zh =
        \\给分屏的每个窗格画上与其内容相符的边框。
        \\
        \\开启后，分屏的标签页里每个窗格都画成一张带标题的卡片：总管的窗格是粗边框，顶边就是它的标题栏；worker 的窗格四周有一条细线和一条标题带；普通终端的标题写在它自己的背景上。标题栏说明是哪个终端，如果是 agent，还说明它此刻在做什么。只有一个普通终端的标签页照旧绘制；总管或 worker 即使单独一个，也带着它的边框。快捷终端从不加边框。
        \\
        \\标题会占掉它下面终端的空间，所以带边框的窗格会比原来矮两行左右。设为 `false`，分屏就照有边框之前的样子画。
        \\
        \\适用于 macOS 和 Windows。在 Windows 上，终端本身保持直角，所以 worker 和普通终端的边框只有顶部是圆角，而且所有边框都没有阴影。
        ,
    },
    .{
        .key = .@"poltergeist-worktree-location",
        .en = "Where a worktree goes when a supervisor opens a terminal with one (`terminal_open` or `role_launch` with `worktree`).",
        .zh = "总管用 worktree 打开终端时（`terminal_open`，或带 `worktree` 的 `role_launch`），worktree 放在哪里。",
        .full_en =
        \\Where a worktree goes when a supervisor opens a terminal with one
        \\(`terminal_open` or `role_launch` with `worktree`).
        \\
        \\  * `beside` (the default): next to the repository, in a directory named
        \\    after it -- for a repository at `~/src/proj`, the tree `fix-1` is
        \\    `~/src/proj-wt/fix-1`, on a new branch `wt/fix-1`.
        \\
        \\  * `inside`: in the repository, under `.polter-worktrees/`. Polter adds
        \\    that directory to the repository's own `.git/info/exclude` so that it
        \\    cannot be committed; your `.gitignore` is not changed.
        \\
        \\Only new trees go where this says; one already made stays where it is.
        \\A directory that is not a git repository gets no tree either way: the
        \\terminal opens there, and the supervisor is told it is not isolated.
        ,
        .full_zh =
        \\总管用 worktree 打开终端时（`terminal_open`，或带 `worktree` 的 `role_launch`），worktree 放在哪里。
        \\
        \\  * `beside`（默认）：放在仓库旁边、以仓库命名的目录里。例如仓库在 `~/src/proj`，树 `fix-1` 就是 `~/src/proj-wt/fix-1`，在新分支 `wt/fix-1` 上。
        \\
        \\  * `inside`：放在仓库里，`.polter-worktrees/` 下面。Polter 会把这个目录加进仓库自己的 `.git/info/exclude`，这样它不会被提交；你的 `.gitignore` 不会被改动。
        \\
        \\只有新建的树才放到这里说的位置；已经建好的留在原处。不是 git 仓库的目录，两种设置下都不建树：终端就在那里打开，并告诉总管它没有被隔离。
        ,
    },
    .{
        .key = .@"polter-control-room-at-launch",
        .en = "Open the control room when Polter starts.",
        .zh = "Polter 启动时打开总控台。",
        .full_en =
        \\Open the control room when Polter starts.
        \\
        \\Only when the application starts: a new window, or a new tab, never
        \\opens it. What it does depends on what was restored (`window-save-state`):
        \\
        \\  * Nothing restored -- the first launch, or a launch with no saved
        \\    windows: one window is opened with the control room as its first tab
        \\    and an empty terminal, in the usual working directory, as its second.
        \\    The control room is in front.
        \\
        \\  * Windows restored -- a restored control room is left as it was. If
        \\    none was restored, the control room is put first among the tabs of
        \\    the front window, behind the tab that was in front, which keeps the
        \\    keyboard. No extra terminal is opened: there are terminals already.
        \\
        \\On macOS, with `initial-window = false` and nothing restored, no window
        \\is opened at all, as before. Windows does not restore tabs, so there it
        \\is always the first case.
        \\
        \\Set this to `false` to start the way Polter did before: the control room
        \\opens only from its menu item or key binding.
        ,
        .full_zh =
        \\Polter 启动时打开总控台。
        \\
        \\只在应用启动时：新窗口或新标签页都不会打开它。它做什么，取决于恢复了什么（`window-save-state`）：
        \\
        \\  * 什么都没恢复（第一次启动，或者没有保存的窗口）：打开一个窗口，第一个标签页是总控台，第二个是一个空终端，在通常的工作目录里。总控台在前面。
        \\
        \\  * 恢复了窗口：恢复出来的总控台保持原样。如果没有恢复总控台，就把它放在最前面那个窗口的标签页里的第一位，在原来位于前面的那个标签页后面，键盘仍留在那个标签页。不会额外打开终端：终端已经有了。
        \\
        \\在 macOS 上，`initial-window = false` 且什么都没恢复时，照旧不打开任何窗口。Windows 不恢复标签页，所以在那里总是第一种情况。
        \\
        \\设为 `false`，就照 Polter 以前那样启动：总控台只能从它的菜单项或快捷键打开。
        ,
    },
    .{
        .key = .@"poltergeist-chat-log",
        .en = "Write what the terminals say to each other to disk.",
        .zh = "把终端之间的对话写到磁盘。",
        .full_en =
        \\Write what the terminals say to each other to disk.
        \\
        \\The conversation in memory is a working set: it trims as it grows, and
        \\the supervisor compacts it on purpose to keep the agents' context free.
        \\That is the wrong shape for a record, and unattended overnight is the
        \\case this whole feature exists for -- without this, the morning after
        \\has nothing to read.
        \\
        \\The log is append-only and nothing removes anything from it: messages
        \\trimmed or compacted away in memory are still in the file. It lives in
        \\`$XDG_STATE_HOME/polter/chat/` and is created owner-only.
        \\
        \\It is written in two shapes, under that same directory, and they differ
        \\in what they cost you:
        \\
        \\  * `chat.jsonl` -- one flat file that rotates past 8MB keeping one
        \\    older generation, so it is bounded at roughly 16MB. This one is for
        \\    the machine, and it forgets: past two generations, gone.
        \\  * `<group>/<date>.jsonl` -- one directory per group, one file per
        \\    day. This is the one to grep the morning after, and **it is never
        \\    rotated and never trimmed**. It is therefore unbounded: it grows
        \\    for as long as the agents keep talking. A day past 8MB carries on
        \\    in a `.partN` file beside it rather than moving anything aside.
        \\
        \\The second is the fuller of the two by design, so do not read the 16MB
        \\as a cap on what this option costs on disk.
        \\
        \\Turn it off if you would rather nothing was written down. The contents
        \\are whatever the agents paste at each other, which is to say your code,
        \\your paths and your stack traces.
        ,
        .full_zh =
        \\把终端之间的对话写到磁盘。
        \\
        \\内存里的对话是一个工作集：它越长越会被修剪，总管也会有意整理它，好让 agent 的上下文保持空闲。这不适合当作记录，而无人值守的夜里恰恰是这整个功能存在的理由：没有它，第二天早上就没有东西可读。
        \\
        \\日志只追加，任何东西都不会从里面删掉内容：在内存里被修剪或整理掉的消息，文件里仍然有。它在 `$XDG_STATE_HOME/polter/chat/`，创建时只有所有者可访问。
        \\
        \\它在同一个目录下写成两种形式，代价不同：
        \\
        \\  * `chat.jsonl`：一个平铺的文件，超过 8MB 就轮转，保留一代旧的，所以上限大约 16MB。这一份是给程序用的，它会遗忘：超过两代的就没了。
        \\  * `<group>/<date>.jsonl`：每个群一个目录，每天一个文件。第二天早上要 grep 的就是这一份，**它从不轮转，也从不修剪**。所以它没有上限：只要 agent 还在说话，它就一直增长。一天的内容超过 8MB 时，会接着写进旁边的 `.partN` 文件，而不是把什么挪开。
        \\
        \\按设计，第二种是两者中更完整的那一个，所以不要把 16MB 当成这个选项占用磁盘的上限。
        \\
        \\如果你宁愿什么都不写下来，就关掉它。内容是 agent 互相粘贴的任何东西，也就是你的代码、你的路径和你的堆栈信息。
        ,
    },
    .{
        .key = .@"poltergeist-terminal-log",
        .en = "Keep a transcript of what actually ran in each terminal.",
        .zh = "保存每个终端里实际运行过的内容的记录。",
        .full_en =
        \\Keep a transcript of what actually ran in each terminal.
        \\
        \\`poltergeist-chat-log` records what the agents said to each other.
        \\Nothing recorded what any of them *did*, so "why did this thing start
        \\looping at two in the morning" could only be answered out of the agent's
        \\own account of itself. This writes the other half.
        \\
        \\It lives in `$XDG_STATE_HOME/polter/terminals/<terminal>/<date>.jsonl`,
        \\created owner-only, one JSON object per line -- the same shape and the
        \\same reading as the chat record, so `less`, `grep` and `jq` work on both.
        \\
        \\**What is recorded is the lines that have scrolled out of the screen**,
        \\not the raw bytes from the program. The raw stream's size is set by how
        \\often a program redraws rather than by what it says: a spinner at 10fps
        \\for eight hours is hundreds of megabytes of nothing. A committed line has
        \\already had the redraws taken out of it.
        \\
        \\Two consequences follow, and they are the point rather than bugs:
        \\
        \\  * **Full-screen programs are nearly blank in it.** `vim`, `htop` and
        \\    anything else using the alternate screen do not write to scrollback,
        \\    so they leave almost nothing. You would not want every frame of
        \\    `htop`; this is what not having it looks like.
        \\  * **The last screenful arrives when the terminal closes.** A line is
        \\    recorded once it has scrolled off; whatever is still on screen is
        \\    written at shutdown.
        \\
        \\**Nothing is redacted.** Terminal output contains API keys, tokens and
        \\paths, and a scrubber that catches nine keys in ten would be worse than
        \\none -- it would make the file feel safe to send somewhere, and the tenth
        \\key would go with it. Treat this the way you treat your shell history.
        \\
        \\**It is kept going round, not for ever.** One terminal running a dev
        \\server can write hundreds of megabytes in a month. How long each part
        \\is kept depends on what it belongs to -- a group, a project, or
        \\nothing -- and is set by `poltergeist-terminal-log-group-max-mb`,
        \\`poltergeist-terminal-log-project-keep-days` and the rest beside this.
        \\(This used to say the transcript was never rotated or trimmed. That was
        \\true until there was a way to say how much of it to keep.)
        \\
        \\Turn it off if you would rather nothing was written down.
        ,
        .full_zh =
        \\保存每个终端里实际运行过的内容的记录。
        \\
        \\`poltergeist-chat-log` 记录 agent 之间说了什么。之前没有东西记录它们*做*了什么，所以“这个东西为什么在凌晨两点开始死循环”只能从 agent 自己的陈述里找答案。这一项写下另一半。
        \\
        \\它在 `$XDG_STATE_HOME/polter/terminals/<terminal>/<date>.jsonl`，创建时只有所有者可访问，每行一个 JSON 对象，和对话记录同样的格式、同样的读法，所以 `less`、`grep` 和 `jq` 对两者都适用。
        \\
        \\**记录的是滚出屏幕的行**，不是程序输出的原始字节。原始字节流的大小取决于程序重绘得多频繁，而不是它说了什么：一个以 10fps 转了八小时的转圈动画，就是几百 MB 的空白。一行一旦落定，重绘就已经从里面去掉了。
        \\
        \\由此有两个后果，它们是本意，不是缺陷：
        \\
        \\  * **全屏程序在里面几乎是空白的。** `vim`、`htop` 以及其他使用备用屏幕的程序不写回滚内容，所以几乎什么都不留下。你不会想要 `htop` 的每一帧；没有它们就是这个样子。
        \\  * **最后一屏内容在终端关闭时才到。** 一行滚出屏幕时才被记录；还留在屏幕上的内容，在关闭时写入。
        \\
        \\**什么都不打码。** 终端输出里有 API 密钥、token 和路径，而一个十个密钥只能抓住九个的过滤器比没有还糟：它会让人觉得这个文件可以放心发出去，第十个密钥也就跟着发出去了。像对待你的 shell 历史那样对待它。
        \\
        \\**它是循环保留的，不是永久保留。** 一个跑着开发服务器的终端，一个月就能写几百 MB。每一部分保留多久，取决于它属于什么（一个群、一个项目，或者什么都不属于），由 `poltergeist-terminal-log-group-max-mb`、`poltergeist-terminal-log-project-keep-days` 以及它旁边的其他几项设定。（这里以前说记录从不轮转也从不修剪。在有办法设定保留多少之前，那是对的。）
        \\
        \\如果你宁愿什么都不写下来，就关掉它。
        ,
    },
    .{
        .key = .@"poltergeist-terminal-log-keep-days",
        .en = "How many days of a terminal's transcript are kept when, at the time it was written, the terminal was in no group and no project. `unlimited` keeps them for ever.",
        .zh = "写下记录时不在任何群、也不在任何项目里的终端，其记录保留多少天。`unlimited` 表示永久保留。",
        .full_en =
        \\How many days of a terminal's transcript are kept when, at the time it
        \\was written, the terminal was in no group and no project. `unlimited`
        \\keeps them for ever.
        \\
        \\The oldest go first, once a day has passed this many. Today's file of a
        \\terminal that is still writing is never deleted. See also
        \\`poltergeist-terminal-log-max-mb`.
        \\
        \\Checked when Polter starts and every hour after, by the application
        \\itself and not by any command it runs.
        ,
        .full_zh =
        \\写下记录时不在任何群、也不在任何项目里的终端，其记录保留多少天。`unlimited` 表示永久保留。
        \\
        \\超过这么多天后，从最旧的开始删。还在写入的终端当天的文件永远不会被删。另见 `poltergeist-terminal-log-max-mb`。
        \\
        \\Polter 启动时检查一次，之后每小时检查一次，由应用自己做，不借助它运行的任何命令。
        ,
    },
    .{ .key = .@"poltergeist-terminal-log-max-mb", .en = "How many megabytes of transcript, of terminals that were in no group and no project, are kept in all. Past it the oldest files go until what is left fits. `unlimited` sets no total.", .zh = "不在任何群、也不在任何项目里的终端，其记录一共保留多少 MB。超出后从最旧的文件删起，直到剩下的不超限。`unlimited` 表示不设总量上限。" },
    .{ .key = .@"poltergeist-terminal-log-project-keep-days", .en = "How many days of transcript are kept from terminals that were in a project's tab but in no group. `unlimited` keeps them for ever.", .zh = "在某个项目的标签页里、但不在任何群中的终端，其记录保留多少天。`unlimited` 表示永久保留。" },
    .{ .key = .@"poltergeist-terminal-log-project-max-mb", .en = "How many megabytes of transcript are kept, in all, from terminals that were in a project's tab but in no group.", .zh = "在某个项目的标签页里、但不在任何群中的终端，其记录一共保留多少 MB。" },
    .{
        .key = .@"poltergeist-terminal-log-group-max-mb",
        .en = "How many megabytes of transcript are kept, in all, from terminals that were members of a group at the time.",
        .zh = "当时是某个群成员的终端，其记录一共保留多少 MB。",
        .full_en =
        \\How many megabytes of transcript are kept, in all, from terminals that
        \\were members of a group at the time.
        \\
        \\These are kept by size only, never by age: they are the record of the
        \\work a group did, which is what a supervisor looks back through. Set it
        \\to `unlimited` to keep them for as long as the group's chat is kept,
        \\which is for ever.
        ,
        .full_zh =
        \\当时是某个群成员的终端，其记录一共保留多少 MB。
        \\
        \\这些只按大小保留，从不按时间：它们是一个群做过的工作的记录，也就是总管回头翻看的东西。设为 `unlimited`，就和这个群的对话保留得一样久，也就是永久。
        ,
    },
    .{
        .key = .@"poltergeist-log-keep-days",
        .en = "How many days of Polter's own logs are kept: plugins' older log generations, crash reports, the hourly group snapshots, and on Windows the host's log files. `unlimited` keeps them for ever.",
        .zh = "Polter 自己的日志保留多少天，包括插件较旧的日志、崩溃报告、每小时的群快照，以及 Windows 上宿主的日志文件。`unlimited` 表示永久保留。",
        .full_en =
        \\How many days of Polter's own logs are kept: plugins' older log
        \\generations, crash reports, the hourly group snapshots, and on Windows
        \\the host's log files. `unlimited` keeps them for ever.
        \\
        \\Two weeks, because a problem is usually noticed and asked about within
        \\a few days, and the logs from before it are what explain it.
        ,
        .full_zh =
        \\Polter 自己的日志保留多少天，包括插件较旧的日志、崩溃报告、每小时的群快照，以及 Windows 上宿主的日志文件。`unlimited` 表示永久保留。
        \\
        \\两周，因为问题通常在几天之内就会被发现和问起，而能解释它的正是它发生之前的日志。
        ,
    },
    .{ .key = .@"poltergeist-log-max-mb", .en = "How many megabytes of Polter's own logs are kept in all. Past it the oldest go until what is left fits. A log being written now is never deleted.", .zh = "Polter 自己的日志一共保留多少 MB。超出后从最旧的删起，直到剩下的不超限。正在写入的日志永远不会被删除。" },
    .{ .key = .@"poltergeist-shots-keep-days", .en = "How many days of screenshots are kept in the screenshot directory. Only Polter's own screenshots are ever deleted, never anything else in that directory.", .zh = "截图目录里的截图保留多少天。只会删除 Polter 自己的截图，目录里的其他文件不会动。" },
    .{ .key = .@"poltergeist-shots-max-mb", .en = "How many megabytes of screenshots are kept in all.", .zh = "截图一共保留多少 MB。" },
    .{
        .key = .@"poltergeist-notify",
        .en = "Deprecated, and does nothing.",
        .zh = "已弃用，不起作用。",
        .full_en =
        \\Deprecated, and does nothing.
        \\
        \\Whether a plugin is switched on now lives in the plugin's own file,
        \\`$XDG_CONFIG_HOME/polter/plugins/<name>.json`, alongside its parameters:
        \\
        \\    {"enabled": true, "params": {"url": "cmd:op read op://Private/hook"}}
        \\
        \\One plugin, one file. Splitting "is it on" from "how is it set up" meant
        \\the two could disagree, and meant nothing could offer a settings screen
        \\without writing to the config file you hand-write.
        \\
        \\Setting this logs a warning saying so. It is not read.
        ,
        .full_zh =
        \\已弃用，不起作用。
        \\
        \\插件是否开启，现在写在插件自己的文件 `$XDG_CONFIG_HOME/polter/plugins/<name>.json` 里，和它的参数放在一起：
        \\
        \\    {"enabled": true, "params": {"url": "cmd:op read op://Private/hook"}}
        \\
        \\一个插件，一个文件。把“开没开”和“怎么设置”分开，意味着两者可能不一致，也意味着没有东西能提供设置界面，除非去写你手写的配置文件。
        \\
        \\设置它会在日志里记一条警告说明这一点。它不会被读取。
        ,
    },
    .{
        .key = .@"poltergeist-notify-window",
        .en = "When it is acceptable to disturb you, as `HH:MM-HH:MM` in local time.",
        .zh = "什么时段可以打扰你，写成本地时间的 `HH:MM-HH:MM`。",
        .full_en =
        \\When it is acceptable to disturb you, as `HH:MM-HH:MM` in local time.
        \\
        \\Outside this window a scheduling question -- keep going, change tack,
        \\give up -- is left to the supervisor, which is what unattended running
        \\means. **A tool-authorisation prompt is sent anyway.** Nobody may
        \\answer those on your behalf, so the choice there is not "disturb you or
        \\decide for you" but "disturb you or let the terminal sit until
        \\morning", and a night wasted costs more than a notification does.
        \\
        \\The control room's own notifications (somebody has waited two minutes
        \\for you) follow the same rule: an approval at any hour, an answer or a
        \\failure held until this window opens.
        \\
        \\Empty means any time is acceptable.
        ,
        .full_zh =
        \\什么时段可以打扰你，写成本地时间的 `HH:MM-HH:MM`。
        \\
        \\在这个时段之外，安排上的问题（继续、换个做法、放弃）交给总管去定，这就是无人值守运行的意思。**工具授权提示照样会发出。** 那些没有人可以代你回答，所以那里的选择不是“打扰你还是替你决定”，而是“打扰你还是让终端一直等到早上”，而浪费一夜比一条通知代价更大。
        \\
        \\总控台自己的通知（有人已经等了你两分钟）也遵守同一条规则：审批随时都发，答复或失败留到这个时段开始再发。
        \\
        \\留空表示任何时候都可以。
        ,
    },
    .{
        .key = .env,
        .en = "Extra environment variables to pass to commands launched in a terminal surface. The format is `env=KEY=VALUE`.",
        .zh = "传给在终端里启动的命令的额外环境变量。格式为 `env=KEY=VALUE`。",
        .full_en =
        \\Extra environment variables to pass to commands launched in a terminal
        \\surface. The format is `env=KEY=VALUE`.
        \\
        \\`env = foo=bar`
        \\`env = bar=baz`
        \\
        \\Setting `env` to an empty string will reset the entire map to default
        \\(empty).
        \\
        \\`env =`
        \\
        \\Setting a key to an empty string will remove that particular key and
        \\corresponding value from the map.
        \\
        \\`env = foo=bar`
        \\`env = foo=`
        \\
        \\will result in `foo` not being passed to the launched commands.
        \\
        \\Setting a key multiple times will overwrite previous entries.
        \\
        \\`env = foo=bar`
        \\`env = foo=baz`
        \\
        \\will result in `foo=baz` being passed to the launched commands.
        \\
        \\These environment variables will override any existing environment
        \\variables set by Ghostty. For example, if you set `GHOSTTY_RESOURCES_DIR`
        \\then the value you set here will override the value Ghostty typically
        \\automatically injects.
        \\
        \\These environment variables _will not_ be passed to commands run by Ghostty
        \\for other purposes, like `open` or `xdg-open` used to open URLs in your
        \\browser.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\传给在终端里启动的命令的额外环境变量。格式为 `env=KEY=VALUE`。
        \\
        \\`env = foo=bar`
        \\`env = bar=baz`
        \\
        \\把 `env` 设为空字符串，会把整个映射重置为默认值（空）。
        \\
        \\`env =`
        \\
        \\把某个键设为空字符串，会从映射里删掉这个键和对应的值。
        \\
        \\`env = foo=bar`
        \\`env = foo=`
        \\
        \\结果是 `foo` 不会传给启动的命令。
        \\
        \\多次设置同一个键，后面的会覆盖前面的。
        \\
        \\`env = foo=bar`
        \\`env = foo=baz`
        \\
        \\结果是 `foo=baz` 传给启动的命令。
        \\
        \\这些环境变量会覆盖 Ghostty 设置的同名环境变量。例如，如果你设置了 `GHOSTTY_RESOURCES_DIR`，你在这里设的值会覆盖 Ghostty 通常会自动注入的值。
        \\
        \\这些环境变量_不会_传给 Ghostty 为其他目的运行的命令，比如用来在浏览器里打开 URL 的 `open` 或 `xdg-open`。
        \\
        \\自 1.2.0 起可用。
        ,
    },
    .{
        .key = .input,
        .en = "Data to send as input to the command on startup.",
        .zh = "启动时作为输入发送给命令的数据。",
        .full_en =
        \\Data to send as input to the command on startup.
        \\
        \\The configured `command` will be launched using the typical rules,
        \\then the data specified as this input will be written to the pty
        \\before any other input can be provided.
        \\
        \\The bytes are sent as-is with no additional encoding. Therefore, be
        \\cautious about input that can contain control characters, because this
        \\can be used to execute programs in a shell.
        \\
        \\The format of this value is:
        \\
        \\  * `raw:<string>` - Send raw text as-is. This uses Zig string literal
        \\    syntax so you can specify control characters and other standard
        \\    escapes.
        \\
        \\  * `path:<path>` - Read a filepath and send the contents. The path
        \\    must be to a file with finite length. e.g. don't use a device
        \\    such as `/dev/stdin` or `/dev/urandom` as these will block
        \\    terminal startup indefinitely. Files are limited to 10MB
        \\    in size to prevent excessive memory usage. If you have files
        \\    larger than this you should write a script to read the file
        \\    and send it to the terminal.
        \\
        \\If no valid prefix is found, it is assumed to be a `raw:` input.
        \\This is an ergonomic choice to allow you to simply write
        \\`input = "Hello, world!"` (a common case) without needing to prefix
        \\every value with `raw:`.
        \\
        \\This can be repeated multiple times to send more data. The data
        \\is concatenated directly with no separator characters in between
        \\(e.g. no newline).
        \\
        \\If any of the input sources do not exist, then none of the input
        \\will be sent. Input sources are not verified until the terminal
        \\is starting, so missing paths will not show up in config validation.
        \\
        \\Changing this configuration at runtime will only affect new
        \\terminals.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\启动时作为输入发送给命令的数据。
        \\
        \\配置的 `command` 会按通常的规则启动，然后这里指定的数据会在任何其他输入之前写进 pty。
        \\
        \\这些字节原样发送，不做额外编码。所以对可能包含控制字符的输入要小心，因为它可以用来在 shell 里执行程序。
        \\
        \\这个值的格式是：
        \\
        \\  * `raw:<string>`：原样发送文本。使用 Zig 字符串字面量的语法，所以可以写控制字符和其他标准转义。
        \\
        \\  * `path:<path>`：读取一个文件并发送其内容。路径必须指向一个长度有限的文件，例如不要用 `/dev/stdin` 或 `/dev/urandom` 这样的设备，它们会让终端启动无限期卡住。为避免占用过多内存，文件大小限制为 10MB。如果你的文件比这大，应该写个脚本读取文件再发送给终端。
        \\
        \\如果找不到有效的前缀，就当作 `raw:` 输入。这是为了方便，让你可以直接写 `input = "Hello, world!"`（常见情况），而不必给每个值都加上 `raw:` 前缀。
        \\
        \\可以重复多次来发送更多数据。数据直接首尾相连，中间没有任何分隔字符（例如没有换行）。
        \\
        \\只要有任何一个输入来源不存在，所有输入都不会发送。输入来源要到终端启动时才校验，所以缺失的路径不会出现在配置校验里。
        \\
        \\在运行时修改这项配置，只影响新的终端。
        \\
        \\自 1.2.0 起可用。
        ,
    },
    .{
        .key = .@"wait-after-command",
        .en = "If true, keep the terminal open after the command exits. Normally, the terminal window closes when the running command (such as a shell) exits. With this true, the terminal window will stay open until any keypress is received.",
        .zh = "设为 true 时，命令退出后保持终端打开。通常，运行的命令（如 shell）退出后，终端窗口就关闭。设为 true 后，终端窗口会一直开着，直到收到任意按键。",
        .full_en =
        \\If true, keep the terminal open after the command exits. Normally, the
        \\terminal window closes when the running command (such as a shell) exits.
        \\With this true, the terminal window will stay open until any keypress is
        \\received.
        \\
        \\This is primarily useful for scripts or debugging.
        ,
        .full_zh =
        \\设为 true 时，命令退出后保持终端打开。通常，运行的命令（如 shell）退出后，终端窗口就关闭。设为 true 后，终端窗口会一直开着，直到收到任意按键。
        \\
        \\主要用于脚本或调试。
        ,
    },
    .{
        .key = .@"abnormal-command-exit-runtime",
        .en = "The number of milliseconds of runtime below which we consider a process exit to be abnormal. This is used to show an error message when the process exits too quickly.",
        .zh = "运行时间低于多少毫秒的进程退出，会被视为异常。进程退出得太快时，据此显示错误信息。",
        .full_en =
        \\The number of milliseconds of runtime below which we consider a process exit
        \\to be abnormal. This is used to show an error message when the process exits
        \\too quickly.
        \\
        \\On Linux, this must be paired with a non-zero exit code. On macOS, we allow
        \\any exit code because of the way shell processes are launched via the login
        \\command.
        ,
        .full_zh =
        \\运行时间低于多少毫秒的进程退出，会被视为异常。进程退出得太快时，据此显示错误信息。
        \\
        \\在 Linux 上，还必须同时有非零的退出码。在 macOS 上，由于 shell 进程是通过 login 命令启动的，任何退出码都算。
        ,
    },
    .{
        .key = .@"scrollback-limit-bytes",
        .en = "The size of the scrollback buffer in bytes. This also includes the active screen. No matter what this is set to, enough memory will always be allocated for the visible screen and anything leftover is the limit for the scrollback.",
        .zh = "回滚缓冲区的大小，单位为字节，包含当前活动屏幕。无论设为多少，总会为可见屏幕分配足够的内存，剩下的才是回滚的上限。",
        .full_en =
        \\The size of the scrollback buffer in bytes. This also includes the active
        \\screen. No matter what this is set to, enough memory will always be
        \\allocated for the visible screen and anything leftover is the limit for
        \\the scrollback.
        \\
        \\When this limit is reached, the oldest lines are removed from the
        \\scrollback.
        \\
        \\Scrollback is stored in memory and allocated lazily up to this limit, so
        \\setting a very large limit does not immediately consume that amount of
        \\memory. On supported systems with scrollback compression enabled, Ghostty
        \\attempts to compress fully historical pages which are not currently visible
        \\while the terminal is idle. This can reduce physical memory usage, depending
        \\on the contents of the scrollback.
        \\
        \\This limit always measures the uncompressed logical size of the terminal
        \\pages. Compression does not allow Ghostty to retain more history than the
        \\configured limit. Accessing compressed history restores it transparently
        \\and may increase the terminal's physical memory usage again.
        \\
        \\This size is per terminal surface, not for the entire application.
        \\
        \\A separate maximum can be set with `scrollback-limit-lines`; if both limits
        \\are set, then the first one reached will determine when scrollback is
        \\removed.
        \\
        \\The default is 50 MB. Set this to `unlimited` to remove the byte limit.
        \\
        \\This can be changed at runtime but will only affect new terminal surfaces.
        ,
        .full_zh =
        \\回滚缓冲区的大小，单位为字节，包含当前活动屏幕。无论设为多少，总会为可见屏幕分配足够的内存，剩下的才是回滚的上限。
        \\
        \\达到上限时，从回滚内容里删掉最旧的行。
        \\
        \\回滚内容存在内存里，按需分配，直到这个上限，所以设一个很大的上限并不会立刻占用那么多内存。在支持的系统上、启用了回滚压缩时，Ghostty 会在终端空闲时尝试压缩当前不可见的、完全属于历史的页。视回滚内容而定，这可以降低物理内存占用。
        \\
        \\这个上限始终按终端页未压缩的逻辑大小来算。压缩不会让 Ghostty 保留超过所配置上限的历史。访问被压缩的历史时会透明地恢复它，终端的物理内存占用也可能因此再次增加。
        \\
        \\这个大小是每个终端各自的，不是整个应用的。
        \\
        \\可以用 `scrollback-limit-lines` 另设一个上限；两个都设时，先达到的那个决定何时删除回滚内容。
        \\
        \\默认 50 MB。设为 `unlimited` 取消字节上限。
        \\
        \\可以在运行时修改，但只影响新的终端。
        ,
    },
    .{
        .key = .@"scrollback-limit-lines",
        .en = "The maximum number of lines of scrollback to retain. This excludes the active screen. Soft-wrapped lines count as multiple lines.",
        .zh = "最多保留多少行回滚内容，不含当前活动屏幕。软换行的行按多行计算。",
        .full_en =
        \\The maximum number of lines of scrollback to retain. This excludes
        \\the active screen. Soft-wrapped lines count as multiple lines.
        \\
        \\This limit is an estimate. Internally, Ghostty will only trim lines
        \\up to the minimum allocation unit that is used internally (called a
        \\"page"). The size of a page depends on how many styles, graphemes, etc.
        \\take up the screen. In practice, this can be anywhere from a handful to
        \\a couple hundred lines. Importantly, memory is capped either way.
        \\This means that the actual limited lines will likely be slightly
        \\higher in practice.
        \\
        \\The default is `unlimited`. A separate maximum can be set with
        \\`scrollback-limit-bytes`; if both limits are set, then the first one reached
        \\will determine when scrollback is removed.
        \\
        \\This can be changed at runtime but will only affect new terminal surfaces.
        ,
        .full_zh =
        \\最多保留多少行回滚内容，不含当前活动屏幕。软换行的行按多行计算。
        \\
        \\这个上限是一个估计值。在内部，Ghostty 只会按内部使用的最小分配单位（称为“页”）来删行。一页有多大，取决于屏幕上有多少样式、字素等。实际上，这可能是从几行到几百行不等。重要的是，内存无论如何都有上限。这意味着实际保留的行数通常会比这个上限略多。
        \\
        \\默认是 `unlimited`。可以用 `scrollback-limit-bytes` 另设一个上限；两个都设时，先达到的那个决定何时删除回滚内容。
        \\
        \\可以在运行时修改，但只影响新的终端。
        ,
    },
    .{
        .key = .@"project-scrollback-limit-bytes",
        .en = "How much of each pane's scrollback is saved with a project, in bytes of saved file per pane. When the project is reopened, each pane shows what it last showed, back as far as this allowed. `0` saves nothing and restores nothing.",
        .zh = "随项目保存每个窗格回滚内容的量，单位为每个窗格保存文件的字节数。重新打开项目时，每个窗格会显示它上次显示的内容，在这个上限允许的范围内尽量往回。`0` 表示什么都不保存、什么都不恢复。",
        .full_en =
        \\How much of each pane's scrollback is saved with a project, in bytes of
        \\saved file per pane. When the project is reopened, each pane shows what
        \\it last showed, back as far as this allowed. `0` saves nothing and
        \\restores nothing.
        \\
        \\This is a cap on the file, separate from `scrollback-limit-bytes` (what a
        \\live terminal keeps in memory), because it is paid again for every pane
        \\of every saved project. When the scrollback is bigger than this, the
        \\**most recent** part is kept. There is no expiry: a project opened months
        \\later shows the same content.
        \\
        \\The default is 10 MB. As a rough guide, on an 80 column terminal that
        \\holds about 120,000 rows of dense plain text, 100,000 rows of colored
        \\`git log --stat`, 65,000 rows of colored `git log -p`, and 25,000 rows of
        \\output where every line is colored and has wide characters (a colored
        \\`ls -la` in a CJK locale).
        \\
        \\Kitty graphics are not saved: an image comes back as the blank space it
        \\occupied.
        ,
        .full_zh =
        \\随项目保存每个窗格回滚内容的量，单位为每个窗格保存文件的字节数。重新打开项目时，每个窗格会显示它上次显示的内容，在这个上限允许的范围内尽量往回。`0` 表示什么都不保存、什么都不恢复。
        \\
        \\这是文件的上限，和 `scrollback-limit-bytes`（活着的终端在内存里保留多少）是分开的，因为每个已保存项目的每个窗格都要再付一次这份代价。回滚内容比这大时，保留**最新**的部分。没有过期：几个月后再打开项目，显示的还是同样的内容。
        \\
        \\默认 10 MB。大致来说，在 80 列的终端上，这能装下大约 120,000 行密集的纯文本、100,000 行带颜色的 `git log --stat`、65,000 行带颜色的 `git log -p`，或者 25,000 行每行都带颜色且有宽字符的输出（中日韩语言环境下带颜色的 `ls -la`）。
        \\
        \\Kitty 图形不会保存：图片恢复后是它原来占的那块空白。
        ,
    },
    .{
        .key = .@"project-scrollback-autosave-interval",
        .en = "How often a pane that belongs to a project saves its scrollback while it runs, so that a crash, a forced restart or a power cut loses at most this much. A pane with no output since the last save writes nothing. Each save writes only what changed -- new pages of history and the visible screen -- not the whole scrollback again.",
        .zh = "属于某个项目的窗格在运行时隔多久保存一次回滚内容，这样崩溃、强制重启或断电最多丢失这么长时间的内容。自上次保存后没有新输出的窗格不会写入。每次只写变化的部分——新增的历史页和可见屏幕——而不是再写一遍整个回滚内容。",
        .full_en =
        \\How often a pane that belongs to a project saves its scrollback while it
        \\runs, so that a crash, a forced restart or a power cut loses at most this
        \\much. A pane with no output since the last save writes nothing. Each save
        \\writes only what changed -- new pages of history and the visible screen --
        \\not the whole scrollback again.
        \\
        \\`0` saves only when the pane is closed or the project is saved.
        ,
        .full_zh =
        \\属于某个项目的窗格在运行时隔多久保存一次回滚内容，这样崩溃、强制重启或断电最多丢失这么长时间的内容。自上次保存后没有新输出的窗格不会写入。每次只写变化的部分——新增的历史页和可见屏幕——而不是再写一遍整个回滚内容。
        \\
        \\`0` 表示只在窗格关闭或项目保存时才保存。
        ,
    },
    .{
        .key = .@"scrollback-compression",
        .en = "Whether to compress scrollback pages while the terminal is idle.",
        .zh = "终端空闲时，是否压缩回滚页。",
        .full_en =
        \\Whether to compress scrollback pages while the terminal is idle.
        \\
        \\Ghostty does its best to only compress when idle and decompress
        \\as needed. This means that compression doesn't lower IO throughput.
        \\We recommend you keep it on.
        \\
        \\The scrollback limit remains an uncompressed logical limit regardless of
        \\this setting, so disabling compression can increase physical memory usage
        \\but does not change how much history is retained.
        \\
        \\Text-heavy terminal history generally compresses to approximately 10% to
        \\30% of its uncompressed page memory, corresponding to a 70% to 90% reduction
        \\in physical memory for pages which are compressed. Compression savings are
        \\content-dependent.
        \\
        \\Note that the way Ghostty works is that we compress and discard the
        \\physical/resident memory but we retain virtual mappings. You will not
        \\see a decrease in virtual memory usage, but you will see a decrease
        \\in physical/memory usage.
        \\
        \\Changing this at runtime affects future compression work. Pages which are
        \\already compressed remain compressed until their contents are accessed.
        ,
        .full_zh =
        \\终端空闲时，是否压缩回滚页。
        \\
        \\Ghostty 尽量只在空闲时压缩、在需要时解压。这意味着压缩不会降低 IO 吞吐量。我们建议保持开启。
        \\
        \\无论这项怎么设，回滚上限都仍是未压缩的逻辑上限，所以关闭压缩可能增加物理内存占用，但不会改变保留多少历史。
        \\
        \\以文本为主的终端历史，通常能压缩到未压缩页内存的约 10% 到 30%，相当于被压缩的页物理内存减少 70% 到 90%。压缩能省多少取决于内容。
        \\
        \\注意 Ghostty 的做法是压缩并丢弃物理（常驻）内存，但保留虚拟内存映射。你不会看到虚拟内存占用下降，但会看到物理内存占用下降。
        \\
        \\在运行时修改这项，会影响之后的压缩工作。已经压缩的页会保持压缩，直到它们的内容被访问。
        ,
    },
    .{
        .key = .scrollbar,
        .en = "Control when the scrollbar is shown to scroll the scrollback buffer.",
        .zh = "控制何时显示用于滚动回滚缓冲区的滚动条。",
        .full_en =
        \\Control when the scrollbar is shown to scroll the scrollback buffer.
        \\
        \\The default value is `system`.
        \\
        \\Valid values:
        \\
        \\  * `system` - Respect the system settings for when to show scrollbars.
        \\    On macOS, we only show scrollbars while actively scrolling or hovering
        \\    the gutter. If the system setting is set to "Always", the scrollbar
        \\    will be shown when the mouse is over the gutter area.
        \\
        \\  * `never` - Never show a scrollbar. You can still scroll using the mouse,
        \\    keybind actions, etc. but you will not have a visual UI widget showing
        \\    a scrollbar.
        ,
        .full_zh =
        \\控制何时显示用于滚动回滚缓冲区的滚动条。
        \\
        \\默认值是 `system`。
        \\
        \\有效值：
        \\
        \\  * `system`：遵从系统设置决定何时显示滚动条。在 macOS 上，我们只在正在滚动或鼠标悬停在边栏上时显示滚动条。如果系统设置为“始终”，鼠标在边栏区域上时会显示滚动条。
        \\
        \\  * `never`：从不显示滚动条。你仍然可以用鼠标、快捷键动作等滚动，只是不会有显示滚动条的界面控件。
        ,
    },
    .{
        .key = .link,
        .en = "Match a regular expression against the terminal text and associate clicking it with an action. This can be used to match URLs, file paths, etc. Actions can be opening using the system opener (e.g. `open` or `xdg-open`) or executing any arbitrary binding action.",
        .zh = "用正则表达式匹配终端文本，并把点击匹配到的内容与某个动作关联。可用来匹配 URL、文件路径等。动作可以是用系统打开程序（如 `open` 或 `xdg-open`）打开，也可以是执行任意绑定动作。",
        .full_en =
        \\Match a regular expression against the terminal text and associate clicking
        \\it with an action. This can be used to match URLs, file paths, etc. Actions
        \\can be opening using the system opener (e.g. `open` or `xdg-open`) or
        \\executing any arbitrary binding action.
        \\
        \\Links that are configured earlier take precedence over links that are
        \\configured later.
        \\
        \\A default link that matches a URL and opens it in the system opener always
        \\exists. This can be disabled using `link-url`.
        \\
        \\TODO: This can't currently be set!
        ,
        .full_zh =
        \\用正则表达式匹配终端文本，并把点击匹配到的内容与某个动作关联。可用来匹配 URL、文件路径等。动作可以是用系统打开程序（如 `open` 或 `xdg-open`）打开，也可以是执行任意绑定动作。
        \\
        \\先配置的链接优先于后配置的链接。
        \\
        \\总有一个默认链接，匹配 URL 并用系统打开程序打开它。可以用 `link-url` 禁用它。
        \\
        \\TODO：目前还不能设置这一项！
        ,
    },
    .{
        .key = .@"link-url",
        .en = "Enable URL matching. URLs are matched on hover with control (Linux) or command (macOS) pressed and open using the default system application for the linked URL.",
        .zh = "启用 URL 匹配。按住 control（Linux）或 command（macOS）悬停时匹配 URL，并用该 URL 对应的系统默认应用打开。",
        .full_en =
        \\Enable URL matching. URLs are matched on hover with control (Linux) or
        \\command (macOS) pressed and open using the default system application for
        \\the linked URL.
        \\
        \\The URL matcher is always lowest priority of any configured links (see
        \\`link`). If you want to customize URL matching, use `link` and disable this.
        ,
        .full_zh =
        \\启用 URL 匹配。按住 control（Linux）或 command（macOS）悬停时匹配 URL，并用该 URL 对应的系统默认应用打开。
        \\
        \\URL 匹配器的优先级总是低于任何配置的链接（见 `link`）。如果你想自定义 URL 匹配，就用 `link`，并禁用这一项。
        ,
    },
    .{
        .key = .@"link-osc8",
        .en = "Enable hyperlinks created with the OSC 8 escape sequence. When disabled, OSC 8 hyperlinks are not highlighted, previewed, copied, or opened.",
        .zh = "启用用 OSC 8 转义序列创建的超链接。禁用后，OSC 8 超链接不会被高亮、预览、复制或打开。",
        .full_en =
        \\Enable hyperlinks created with the OSC 8 escape sequence. When disabled,
        \\OSC 8 hyperlinks are not highlighted, previewed, copied, or opened.
        \\
        \\This does not affect URL matching controlled by `link-url`.
        \\
        \\Available since: 1.4.0
        ,
        .full_zh =
        \\启用用 OSC 8 转义序列创建的超链接。禁用后，OSC 8 超链接不会被高亮、预览、复制或打开。
        \\
        \\这不影响由 `link-url` 控制的 URL 匹配。
        \\
        \\自 1.4.0 起可用。
        ,
    },
    .{
        .key = .@"link-previews",
        .en = "Show link previews for a matched URL.",
        .zh = "为匹配到的 URL 显示链接预览。",
        .full_en =
        \\Show link previews for a matched URL.
        \\
        \\When true, link previews are shown for all matched URLs. When false, link
        \\previews are never shown. When set to "osc8", link previews are only shown
        \\for hyperlinks created with the OSC 8 sequence (in this case, the link text
        \\can differ from the link destination).
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\为匹配到的 URL 显示链接预览。
        \\
        \\设为 true 时，所有匹配到的 URL 都显示链接预览。设为 false 时，从不显示链接预览。设为 "osc8" 时，只为用 OSC 8 序列创建的超链接显示链接预览（这种情况下，链接文字可以和链接目标不同）。
        \\
        \\自 1.2.0 起可用。
        ,
    },
    .{
        .key = .maximize,
        .en = "Whether to start the window in a maximized state. This setting applies to new windows and does not apply to tabs, splits, etc. However, this setting will apply to all new windows, not just the first one.",
        .zh = "新窗口是否以最大化状态启动。此设置适用于新窗口，不适用于标签页、分屏等。不过它对所有新窗口都生效，而不只是第一个。",
        .full_en =
        \\Whether to start the window in a maximized state. This setting applies
        \\to new windows and does not apply to tabs, splits, etc. However, this setting
        \\will apply to all new windows, not just the first one.
        \\
        \\Available since: 1.1.0
        ,
        .full_zh =
        \\新窗口是否以最大化状态启动。此设置适用于新窗口，不适用于标签页、分屏等。不过它对所有新窗口都生效，而不只是第一个。
        \\
        \\自 1.1.0 起可用。
        ,
    },
    .{
        .key = .fullscreen,
        .en = "Start new windows in fullscreen. This setting applies to new windows and does not apply to tabs, splits, etc. However, this setting will apply to all new windows, not just the first one.",
        .zh = "新窗口以全屏启动。此设置适用于新窗口，不适用于标签页、分屏等。不过它对所有新窗口都生效，而不只是第一个。",
        .full_en =
        \\Start new windows in fullscreen. This setting applies to new windows and
        \\does not apply to tabs, splits, etc. However, this setting will apply to all
        \\new windows, not just the first one.
        \\
        \\Allowable values are:
        \\
        \\  * `false` - Don't start in fullscreen (default)
        \\  * `true` - Start in native fullscreen
        \\  * `non-native` - (macOS only) Start in non-native fullscreen, hiding the
        \\    menu bar. This is faster than native fullscreen since it doesn't use
        \\    animations. On non-macOS platforms, this behaves the same as `true`.
        \\  * `non-native-visible-menu` - (macOS only) Start in non-native fullscreen,
        \\    keeping the menu bar visible. On non-macOS platforms, behaves like `true`.
        \\  * `non-native-padded-notch` - (macOS only) Start in non-native fullscreen,
        \\    hiding the menu bar but padding for the notch on applicable devices.
        \\    On non-macOS platforms, behaves like `true`.
        \\
        \\Important: tabs DO NOT WORK with non-native fullscreen modes. Non-native
        \\fullscreen removes the titlebar and macOS native tabs require the titlebar.
        \\If you use tabs, use `true` (native) instead.
        \\
        \\On macOS, `true` (native fullscreen) does not work if `window-decoration`
        \\is set to `false`, because native fullscreen on macOS requires window
        \\decorations.
        ,
        .full_zh =
        \\新窗口以全屏启动。此设置适用于新窗口，不适用于标签页、分屏等。不过它对所有新窗口都生效，而不只是第一个。
        \\
        \\可用的值：
        \\
        \\  * `false`：不以全屏启动（默认）
        \\  * `true`：以原生全屏启动
        \\  * `non-native`：（仅 macOS）以非原生全屏启动，隐藏菜单栏。因为不使用动画，它比原生全屏快。在非 macOS 平台上，行为与 `true` 相同。
        \\  * `non-native-visible-menu`：（仅 macOS）以非原生全屏启动，保留菜单栏可见。在非 macOS 平台上，行为与 `true` 相同。
        \\  * `non-native-padded-notch`：（仅 macOS）以非原生全屏启动，隐藏菜单栏，但在有刘海的设备上为刘海留出空间。在非 macOS 平台上，行为与 `true` 相同。
        \\
        \\重要：标签页在非原生全屏模式下完全不能用。非原生全屏会去掉标题栏，而 macOS 原生标签页需要标题栏。如果你使用标签页，请改用 `true`（原生）。
        \\
        \\在 macOS 上，如果 `window-decoration` 设为 `false`，`true`（原生全屏）不起作用，因为 macOS 的原生全屏需要窗口装饰。
        ,
    },
    .{
        .key = .title,
        .en = "The title Ghostty will use for the window. This will force the title of the window to be this title at all times and Ghostty will ignore any set title escape sequences programs (such as Neovim) may send.",
        .zh = "Ghostty 为窗口使用的标题。这会强制窗口标题始终是它，Ghostty 会忽略程序（如 Neovim）可能发来的设置标题的转义序列。",
        .full_en =
        \\The title Ghostty will use for the window. This will force the title of the
        \\window to be this title at all times and Ghostty will ignore any set title
        \\escape sequences programs (such as Neovim) may send.
        \\
        \\If you want a blank title, set this to one or more spaces by quoting
        \\the value. For example, `title = " "`. This effectively hides the title.
        \\This is necessary because setting a blank value resets the title to the
        \\default value of the running program.
        \\
        \\This configuration can be reloaded at runtime. If it is set, the title
        \\will update for all windows. If it is unset, the next title change escape
        \\sequence will be honored but previous changes will not retroactively
        \\be set. This latter case may require you to restart programs such as Neovim
        \\to get the new title.
        ,
        .full_zh =
        \\Ghostty 为窗口使用的标题。这会强制窗口标题始终是它，Ghostty 会忽略程序（如 Neovim）可能发来的设置标题的转义序列。
        \\
        \\如果你想要空白标题，就把它设成一个或多个空格，并给值加上引号，例如 `title = " "`。这实际上会隐藏标题。之所以要这样，是因为设成空值会把标题重置为运行中程序的默认值。
        \\
        \\这项配置可以在运行时重新加载。如果设置了它，所有窗口的标题都会更新。如果取消设置，下一次修改标题的转义序列会被采纳，但之前的修改不会被追溯应用。后一种情况下，你可能需要重启 Neovim 之类的程序才能得到新标题。
        ,
    },
    .{
        .key = .class,
        .en = "The setting that will change the application class value.",
        .zh = "用来改变应用 class 值的设置。",
        .full_en =
        \\The setting that will change the application class value.
        \\
        \\This controls the class field of the `WM_CLASS` X11 property (when running
        \\under X11), the Wayland application ID (when running under Wayland), and the
        \\bus name that Ghostty uses to connect to DBus.
        \\
        \\Note that changing this value between invocations will create new, separate
        \\instances, of Ghostty when running with `gtk-single-instance=true`. See that
        \\option for more details.
        \\
        \\Changing this value may break launching Ghostty from `.desktop` files, via
        \\DBus activation, or systemd user services as the system is expecting Ghostty
        \\to connect to DBus using the default `class` when it is launched.
        \\
        \\The class name must follow the requirements defined [in the GTK
        \\documentation](https://docs.gtk.org/gio/type_func.Application.id_is_valid.html).
        \\
        \\The default is `com.mitchellh.ghostty`.
        \\
        \\This only affects GTK builds.
        ,
        .full_zh =
        \\用来改变应用 class 值的设置。
        \\
        \\它控制 X11 属性 `WM_CLASS` 的 class 字段（在 X11 下运行时）、Wayland 的应用 ID（在 Wayland 下运行时），以及 Ghostty 连接 DBus 所用的总线名。
        \\
        \\注意，在 `gtk-single-instance=true` 下运行时，两次启动之间改变这个值，会创建新的、各自独立的 Ghostty 实例。详见那个选项。
        \\
        \\改变这个值可能导致无法通过 `.desktop` 文件、DBus 激活或 systemd 用户服务启动 Ghostty，因为系统期望 Ghostty 启动时用默认的 `class` 连接 DBus。
        \\
        \\class 名必须符合 [GTK 文档](https://docs.gtk.org/gio/type_func.Application.id_is_valid.html) 里定义的要求。
        \\
        \\默认是 `com.mitchellh.ghostty`。
        \\
        \\只影响 GTK 版本。
        ,
    },
    .{
        .key = .@"x11-instance-name",
        .en = "This controls the instance name field of the `WM_CLASS` X11 property when running under X11. It has no effect otherwise.",
        .zh = "在 X11 下运行时，控制 `WM_CLASS` X11 属性的实例名字段。其他情况下无效。",
        .full_en =
        \\This controls the instance name field of the `WM_CLASS` X11 property when
        \\running under X11. It has no effect otherwise.
        \\
        \\The default is `ghostty`.
        \\
        \\This only affects GTK builds.
        ,
        .full_zh =
        \\在 X11 下运行时，控制 `WM_CLASS` X11 属性的实例名字段。其他情况下无效。
        \\
        \\默认是 `ghostty`。
        \\
        \\只影响 GTK 版本。
        ,
    },
    .{
        .key = .@"working-directory",
        .en = "The directory to change to after starting the command.",
        .zh = "启动命令后要切换到的目录。",
        .full_en =
        \\The directory to change to after starting the command.
        \\
        \\This setting is secondary to the `window-inherit-working-directory`
        \\setting. If a previous Ghostty terminal exists in the same process,
        \\`window-inherit-working-directory` will take precedence. Otherwise, this
        \\setting will be used. Typically, this setting is used only for the first
        \\window.
        \\
        \\The default is `inherit` except in special scenarios listed next. On macOS,
        \\if Ghostty can detect it is launched from launchd (double-clicked) or
        \\`open`, then it defaults to `home`. On Linux with GTK, if Ghostty can detect
        \\it was launched from a desktop launcher, then it defaults to `home`.
        \\
        \\The value of this must be an absolute path, a path prefixed with `~/`
        \\(the tilde will be expanded to the user's home directory), or
        \\one of the special values below:
        \\
        \\  * `home` - The home directory of the executing user.
        \\
        \\  * `inherit` - The working directory of the launching process.
        ,
        .full_zh =
        \\启动命令后要切换到的目录。
        \\
        \\这项设置次于 `window-inherit-working-directory` 设置。如果同一进程里已经有一个 Ghostty 终端，`window-inherit-working-directory` 优先。否则就用这项设置。通常这项设置只用于第一个窗口。
        \\
        \\默认是 `inherit`，下面列出的特殊情况除外。在 macOS 上，如果 Ghostty 能检测到它是从 launchd（双击）或 `open` 启动的，默认就是 `home`。在 Linux 的 GTK 下，如果 Ghostty 能检测到它是从桌面启动器启动的，默认就是 `home`。
        \\
        \\这个值必须是绝对路径、以 `~/` 开头的路径（波浪号会展开为用户的主目录），或者下面的特殊值之一：
        \\
        \\  * `home`：运行用户的主目录。
        \\
        \\  * `inherit`：启动它的进程的工作目录。
        ,
    },
    .{
        .key = .keybind,
        .en = "Key bindings. The format is `trigger=action`. Duplicate triggers will overwrite previously set values. The list of actions is available in the documentation or using the `ghostty +list-actions` command.",
        .zh = "按键绑定。格式为 `trigger=action`。重复的触发键会覆盖之前设置的值。动作列表可在文档中查到，也可用 `ghostty +list-actions` 命令查看。",
        .full_en =
        \\Key bindings. The format is `trigger=action`. Duplicate triggers will
        \\overwrite previously set values. The list of actions is available in
        \\the documentation or using the `ghostty +list-actions` command.
        \\
        \\Trigger: `+`-separated list of keys and modifiers. Example: `ctrl+a`,
        \\`ctrl+shift+b`, `up`.
        \\
        \\If the key is a single Unicode codepoint, the trigger will match
        \\any presses that produce that codepoint. These are impacted by
        \\keyboard layouts. For example, `a` will match the `a` key on a
        \\QWERTY keyboard, but will match the `q` key on a AZERTY keyboard
        \\(assuming US physical layout).
        \\
        \\For Unicode codepoints, matching is done by comparing the set of
        \\modifiers with the unmodified codepoint. The unmodified codepoint is
        \\sometimes called an "unshifted character" in other software, but all
        \\modifiers are considered, not only shift. For example, `ctrl+a` will match
        \\`a` but not `ctrl+shift+a` (which is `A` on a US keyboard).
        \\
        \\Further, codepoint matching is case-insensitive and the unmodified
        \\codepoint is always case folded for comparison. As a result,
        \\`ctrl+A` configured will match when `ctrl+a` is pressed. Note that
        \\this means some key combinations are impossible depending on keyboard
        \\layout. For example, `ctrl+_` is impossible on a US keyboard because
        \\`_` is `shift+-` and `ctrl+shift+-` is not equal to `ctrl+_` (because
        \\the modifiers don't match!). More details on impossible key combinations
        \\can be found at this excellent source written by Qt developers:
        \\https://doc.qt.io/qt-6/qkeysequence.html#keyboard-layout-issues
        \\
        \\Physical key codes can be specified by using any of the key codes
        \\as specified by the [W3C specification](https://www.w3.org/TR/uievents-code/).
        \\For example, `KeyA` will match the physical `a` key on a US standard
        \\keyboard regardless of the keyboard layout. These are case-sensitive.
        \\
        \\For aesthetic reasons, the w3c codes also support snake case. For
        \\example, `key_a` is equivalent to `KeyA`. The only exceptions are
        \\function keys, e.g. `F1` is `f1` (no underscore). This is a consequence
        \\of our internal code using snake case but is purposely supported
        \\and tested so it is safe to use. It allows an all-lowercase binding
        \\which I find more aesthetically pleasing.
        \\
        \\Function keys such as `insert`, `up`, `f5`, etc. are also specified
        \\using the keys as specified by the previously linked W3C specification.
        \\
        \\Physical keys always match with a higher priority than Unicode codepoints,
        \\so if you specify both `a` and `KeyA`, the physical key will always be used
        \\regardless of what order they are configured.
        \\
        \\The special key `catch_all` can be used to match any key that is not
        \\otherwise bound. This can be combined with modifiers, for example
        \\`ctrl+catch_all` will match any key pressed with `ctrl` that is not
        \\otherwise bound. When looking up a binding, Ghostty first tries to match
        \\`catch_all` with modifiers. If no match is found and the event has
        \\modifiers, it falls back to `catch_all` without modifiers.
        \\
        \\Valid modifiers are `shift`, `ctrl` (alias: `control`), `alt` (alias: `opt`,
        \\`option`), and `super` (alias: `cmd`, `command`). You may use the modifier
        \\or the alias. When debugging keybinds, the non-aliased modifier will always
        \\be used in output.
        \\
        \\Note: The fn or "globe" key on keyboards are not supported as a
        \\modifier. This is a limitation of the operating systems and GUI toolkits
        \\that Ghostty uses.
        \\
        \\Some additional notes for triggers:
        \\
        \\  * modifiers cannot repeat, `ctrl+ctrl+a` is invalid.
        \\
        \\  * modifiers and keys can be in any order, `shift+a+ctrl` is *weird*,
        \\    but valid.
        \\
        \\  * only a single key input is allowed, `ctrl+a+b` is invalid.
        \\
        \\You may also specify multiple triggers separated by `>` to require a
        \\sequence of triggers to activate the action. For example,
        \\`ctrl+a>n=new_window` will only trigger the `new_window` action if the
        \\user presses `ctrl+a` followed separately by `n`. In other software, this
        \\is sometimes called a leader key, a key chord, a key table, etc. There
        \\is no hardcoded limit on the number of parts in a sequence.
        \\
        \\Warning: If you define a sequence as a CLI argument to `ghostty`,
        \\you probably have to quote the keybind since `>` is a special character
        \\in most shells. Example: ghostty --keybind='ctrl+a>n=new_window'
        \\
        \\A trigger sequence has some special handling:
        \\
        \\  * Ghostty will wait an indefinite amount of time for the next key in
        \\    the sequence. There is no way to specify a timeout. The only way to
        \\    force the output of a prefix key is to assign another keybind to
        \\    specifically output that key (e.g. `ctrl+a>ctrl+a=text:foo`) or
        \\    press an unbound key which will send both keys to the program.
        \\
        \\  * If an unbound key is pressed during a sequence and a `catch_all`
        \\    binding exists that would `ignore` the input, the entire sequence
        \\    is dropped and nothing happens. Otherwise, the entire sequence is
        \\    encoded and sent to the running program as if no keybind existed.
        \\
        \\  * If a prefix in a sequence is previously bound, the sequence will
        \\    override the previous binding. For example, if `ctrl+a` is bound to
        \\    `new_window` and `ctrl+a>n` is bound to `new_tab`, pressing `ctrl+a`
        \\    will do nothing.
        \\
        \\  * Adding to the above, if a previously bound sequence prefix is
        \\    used in a new, non-sequence binding, the entire previously bound
        \\    sequence will be unbound. For example, if you bind `ctrl+a>n` and
        \\    `ctrl+a>t`, and then bind `ctrl+a` directly, both `ctrl+a>n` and
        \\    `ctrl+a>t` will become unbound.
        \\
        \\  * Trigger sequences are not allowed for `global:` or `all:`-prefixed
        \\    triggers. This is a limitation we could remove in the future.
        \\
        \\Action is the action to take when the trigger is satisfied. It takes the
        \\format `action` or `action:param`. The latter form is only valid if the
        \\action requires a parameter.
        \\
        \\  * `ignore` - Do nothing, ignore the key input. This can be used to
        \\    black hole certain inputs to have no effect.
        \\
        \\  * `unbind` - Remove the binding. This makes it so the previous action
        \\    is removed, and the key will be sent through to the child command
        \\    if it is printable. Unbind will remove any matching trigger,
        \\    including `physical:`-prefixed triggers without specifying the
        \\    prefix.
        \\
        \\  * `csi:text` - Send a CSI sequence. e.g. `csi:A` sends "cursor up".
        \\
        \\  * `esc:text` - Send an escape sequence. e.g. `esc:d` deletes to the
        \\    end of the word to the right.
        \\
        \\  * `text:text` - Send a string. Uses Zig string literal syntax.
        \\    e.g. `text:\x15` sends Ctrl-U.
        \\
        \\  * All other actions can be found in the documentation or by using the
        \\    `ghostty +list-actions` command.
        \\
        \\Some notes for the action:
        \\
        \\  * The parameter is taken as-is after the `:`. Double quotes or
        \\    other mechanisms are included and NOT parsed. If you want to
        \\    send a string value that includes spaces, wrap the entire
        \\    trigger/action in double quotes. Example: `--keybind="up=csi:A B"`
        \\
        \\There are some additional special values that can be specified for
        \\keybind:
        \\
        \\  * `keybind=clear` will clear all set keybindings. Warning: this
        \\    removes ALL keybindings up to this point, including the default
        \\    keybindings.
        \\
        \\The keybind trigger can be prefixed with some special values to change
        \\the behavior of the keybind. These are:
        \\
        \\ * `all:`
        \\
        \\   Make the keybind apply to all terminal surfaces. By default,
        \\   keybinds only apply to the focused terminal surface. If this is true,
        \\   then the keybind will be sent to all terminal surfaces. This only
        \\   applies to actions that are surface-specific. For actions that
        \\   are already global (e.g. `quit`), this prefix has no effect.
        \\
        \\   Available since: 1.0.0
        \\
        \\ * `global:`
        \\
        \\   Make the keybind global. By default, keybinds only work within Ghostty
        \\   and under the right conditions (application focused, sometimes terminal
        \\   focused, etc.). If you want a keybind to work globally across your system
        \\   (e.g. even when Ghostty is not focused), specify this prefix.
        \\   This prefix implies `all:`.
        \\
        \\   Note: this does not work in all environments; see the additional notes
        \\   below for more information.
        \\
        \\   Available since: 1.0.0 on macOS, 1.2.0 on GTK
        \\
        \\ * `unconsumed:`
        \\
        \\   Do not consume the input. By default, a keybind will consume the input,
        \\   meaning that the associated encoding (if any) will not be sent to the
        \\   running program in the terminal. If you wish to send the encoded value
        \\   to the program, specify the `unconsumed:` prefix before the entire
        \\   keybind. For example: `unconsumed:ctrl+a=reload_config`. `global:` and
        \\   `all:`-prefixed keybinds will always consume the input regardless of
        \\   this setting. Since they are not associated with a specific terminal
        \\   surface, they're never encoded.
        \\
        \\   Available since: 1.0.0
        \\
        \\ * `performable:`
        \\
        \\   Only consume the input if the action is able to be performed.
        \\   For example, the `copy_to_clipboard` action will only consume the input
        \\   if there is a selection to copy. If there is no selection, Ghostty
        \\   behaves as if the keybind was not set. This has no effect with `global:`
        \\   or `all:`-prefixed keybinds. For key sequences, this will reset the
        \\   sequence if the action is not performable (acting identically to not
        \\   having a keybind set at all).
        \\
        \\   Performable keybinds will not appear as menu shortcuts in the
        \\   application menu. This is because the menu shortcuts force the
        \\   action to be performed regardless of the state of the terminal.
        \\   Performable keybinds will still work, they just won't appear as
        \\   a shortcut label in the menu.
        \\
        \\   Available since: 1.1.0
        \\
        \\Keybind triggers are not unique per prefix combination. For example,
        \\`ctrl+a` and `global:ctrl+a` are not two separate keybinds. The keybind
        \\set later will overwrite the keybind set earlier. In this case, the
        \\`global:` keybind will be used.
        \\
        \\Multiple prefixes can be specified. For example,
        \\`global:unconsumed:ctrl+a=reload_config` will make the keybind global
        \\and not consume the input to reload the config.
        \\
        \\On macOS, this feature requires accessibility permissions to be granted
        \\to Ghostty. When a `global:` keybind is specified and Ghostty is launched
        \\or reloaded, Ghostty will attempt to request these permissions.
        \\If the permissions are not granted, the keybind will not work. On macOS,
        \\you can find these permissions in System Preferences -> Privacy & Security
        \\-> Accessibility.
        \\
        \\Since Ghostty 1.4.0, global shortcuts on Linux are primarily supported
        \\through the [`vicinae-hotkey-v1`](https://github.com/vicinaehq/vicinae-wayland-protocols/tree/main/staging/vicinae-hotkey)
        \\protocol, available out-of-the-box with the following Wayland compositors
        \\and desktop environments:
        \\
        \\  - Hyprland since version 0.56.0
        \\
        \\On X11 or when your Wayland compositor/desktop environment does not
        \\support `vicinae-hotkey-v1`, the much more widely-used
        \\[XDG Global Shortcuts](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html)
        \\protocol is used instead.
        \\
        \\Note: XDG Global Shortcuts rely on a functional XDG Desktop Portal
        \\implementation **that is designed to be used with your desktop environment
        \\or compositor**. Please make sure that you have the correct one installed.
        \\
        \\Desktop environments that are known to support the XDG Global Shortcuts
        \\protocol include:
        \\
        \\ - KDE Plasma since [5.27](https://kde.org/announcements/plasma/5/5.27.0/#wayland)
        \\   with `xdg-desktop-portal-kde` installed
        \\
        \\ - GNOME since [48](https://release.gnome.org/48/#and-thats-not-all) with
        \\   `xdg-desktop-portal-gnome` installed
        \\
        \\ - Hyprland before version 0.56.0, with `xdg-desktop-portal-hyprland`
        \\   installed. **Some manual configuration is required.** Consult the steps
        \\   outlined on the [Hyprland Wiki](https://wiki.hypr.land/Configuring/Basics/Binds/#dbus-global-shortcuts)
        \\   to set up D-Bus-based global shortcuts correctly.
        \\
        \\Desktop environments and compositors that don't implement either protocol
        \\do not support global shortcuts, like wlroots-based compositors e.g. Sway
        \\(see [upstream issue](https://github.com/emersion/xdg-desktop-portal-wlr/issues/240))
        \\and COSMIC.
        \\
        \\## Chained Actions
        \\
        \\A keybind can have multiple actions by using the `chain` keyword for
        \\subsequent actions. When a keybind is activated, all chained actions are
        \\executed in order. The syntax is:
        \\
        \\```ini
        \\keybind = ctrl+a=new_window
        \\keybind = chain=goto_split:left
        \\```
        \\
        \\This binds `ctrl+a` to first open a new window, then move focus to the
        \\left split. Each `chain` entry appends an action to the most recently
        \\defined keybind. You can chain as many actions as you want:
        \\
        \\```ini
        \\keybind = ctrl+a=new_window
        \\keybind = chain=goto_split:left
        \\keybind = chain=toggle_fullscreen
        \\```
        \\
        \\Chained actions cannot have prefixes like `global:` or `unconsumed:`.
        \\The flags from the original keybind apply to the entire chain.
        \\
        \\Chained actions work with key sequences as well. For example:
        \\
        \\```ini
        \\keybind = ctrl+a>n=new_window
        \\keybind = chain=goto_split:left
        \\````
        \\
        \\Chains with key sequences apply to the most recent binding in the
        \\sequence.
        \\
        \\Chained keybinds are available since Ghostty 1.3.0.
        \\
        \\## Key Tables
        \\
        \\You may also create a named set of keybindings known as a "key table."
        \\A key table must be explicitly activated for the bindings to become
        \\available. This can be used to implement features such as a
        \\"copy mode", "vim mode", etc. Generically, this can implement modal
        \\keyboard input.
        \\
        \\Key tables are defined using the syntax `<table>/<binding>`. The
        \\`<binding>` value is everything documented above for keybinds. The
        \\`<table>` value is the name of the key table. Table names can contain
        \\anything except `/`, `=`, `+`, and `>`. The characters `+` and `>` are
        \\reserved for keybind syntax (modifier combinations and key sequences).
        \\For example `foo/ctrl+a=new_window` defines a binding within a table
        \\named `foo`.
        \\
        \\Tables are activated and deactivated using the binding actions
        \\`activate_key_table:<name>` and `deactivate_key_table`. Other table
        \\related binding actions also exist; see the documentation for a full list.
        \\These are the primary way to interact with key tables.
        \\
        \\Binding lookup proceeds from the innermost table outward, so keybinds in
        \\the default table remain available unless explicitly unbound in an inner
        \\table.
        \\
        \\A key table has some special syntax and handling:
        \\
        \\  * `<name>/` (with no binding) defines and clears a table, resetting all
        \\    of its keybinds and settings.
        \\
        \\  * You cannot activate a table that is already the innermost table; such
        \\    attempts are ignored. However, the same table can appear multiple times
        \\    in the stack as long as it is not innermost (e.g., `A -> B -> A -> B`
        \\    is valid, but `A -> B -> B` is not).
        \\
        \\  * A table can be activated in one-shot mode using
        \\    `activate_key_table_once:<name>`. A one-shot table is automatically
        \\    deactivated when any non-catch-all binding is invoked.
        \\
        \\  * Key sequences work within tables: `foo/ctrl+a>ctrl+b=new_window`.
        \\    If an invalid key is pressed, the sequence ends but the table remains
        \\    active.
        \\
        \\  * Chain actions work within tables, the `chain` keyword applies to
        \\    the most recently defined binding in the table. e.g. if you set
        \\    `table/ctrl+a=new_window` you can chain by using `chain=text:hello`.
        \\    Important: chain itself doesn't get prefixed with the table name,
        \\    since it applies to the most recent binding in any table.
        \\
        \\  * Prefixes like `global:` work within tables:
        \\    `foo/global:ctrl+a=new_window`.
        \\
        \\Key tables are available since Ghostty 1.3.0.
        ,
        .full_zh =
        \\按键绑定。格式为 `trigger=action`。重复的触发键会覆盖之前设置的值。动作列表可在文档中查到，也可用 `ghostty +list-actions` 命令查看。
        \\
        \\触发键：用 `+` 分隔的按键和修饰键列表。例如：`ctrl+a`、`ctrl+shift+b`、`up`。
        \\
        \\如果按键是单个 Unicode 码位，触发键会匹配任何产生该码位的按键。这会受键盘布局影响。例如，`a` 在 QWERTY 键盘上匹配 `a` 键，在 AZERTY 键盘上却匹配 `q` 键（假设物理布局为美式）。
        \\
        \\对于 Unicode 码位，匹配方式是比较修饰键集合和未经修饰的码位。未经修饰的码位在别的软件里有时叫“未按 Shift 的字符”，但这里考虑的是所有修饰键，不只是 Shift。例如，`ctrl+a` 会匹配 `a`，但不匹配 `ctrl+shift+a`（在美式键盘上是 `A`）。
        \\
        \\此外，码位匹配不区分大小写，未经修饰的码位总是先做大小写折叠再比较。因此配置的 `ctrl+A` 在按下 `ctrl+a` 时也会匹配。注意，这意味着视键盘布局而定，有些组合键是不可能的。例如，`ctrl+_` 在美式键盘上不可能，因为 `_` 是 `shift+-`，而 `ctrl+shift+-` 不等于 `ctrl+_`（修饰键不一样！）。关于不可能的组合键，Qt 开发者写的这篇很好的资料里有更多细节：https://doc.qt.io/qt-6/qkeysequence.html#keyboard-layout-issues
        \\
        \\物理键码可以用 [W3C 规范](https://www.w3.org/TR/uievents-code/) 规定的任何键码来指定。例如，`KeyA` 在美式标准键盘上匹配物理的 `a` 键，与键盘布局无关。这些区分大小写。
        \\
        \\出于美观，W3C 键码也支持蛇形命名。例如，`key_a` 等同于 `KeyA`。唯一的例外是功能键，例如 `F1` 写作 `f1`（没有下划线）。这是我们内部代码使用蛇形命名的结果，但这是有意支持并经过测试的，所以可以放心使用。它让绑定可以全用小写，我觉得这样更好看。
        \\
        \\`insert`、`up`、`f5` 等功能键，也用前面链接的 W3C 规范里规定的键名来指定。
        \\
        \\物理键的匹配优先级总是高于 Unicode 码位，所以如果你同时指定了 `a` 和 `KeyA`，无论配置顺序如何，总是使用物理键。
        \\
        \\特殊按键 `catch_all` 可以匹配任何没有另外绑定的按键。它可以和修饰键组合，例如 `ctrl+catch_all` 会匹配任何没有另外绑定、且按着 `ctrl` 的按键。查找绑定时，Ghostty 先尝试匹配带修饰键的 `catch_all`。如果没有匹配，而事件带有修饰键，就退回到不带修饰键的 `catch_all`。
        \\
        \\有效的修饰键是 `shift`、`ctrl`（别名：`control`）、`alt`（别名：`opt`、`option`）和 `super`（别名：`cmd`、`command`）。修饰键和别名都可以用。调试按键绑定时，输出里总是使用非别名的修饰键。
        \\
        \\注意：键盘上的 fn 键或“地球”键不支持作为修饰键。这是 Ghostty 所用的操作系统和图形界面工具包的限制。
        \\
        \\关于触发键的一些补充说明：
        \\
        \\  * 修饰键不能重复，`ctrl+ctrl+a` 无效。
        \\
        \\  * 修饰键和按键可以按任意顺序排列，`shift+a+ctrl` 很*怪*，但有效。
        \\
        \\  * 只允许一个按键输入，`ctrl+a+b` 无效。
        \\
        \\你也可以用 `>` 分隔多个触发键，要求按顺序按下一串触发键才触发动作。例如，`ctrl+a>n=new_window` 只有在用户按下 `ctrl+a`、再单独按下 `n` 时，才会触发 `new_window` 动作。在别的软件里，这有时叫 leader 键、组合和弦、按键表等。一个序列包含几部分没有硬性上限。
        \\
        \\警告：如果你把序列作为 `ghostty` 的命令行参数来定义，很可能要给这个按键绑定加引号，因为 `>` 在大多数 shell 里是特殊字符。示例：ghostty --keybind='ctrl+a>n=new_window'
        \\
        \\触发序列有一些特殊处理：
        \\
        \\  * Ghostty 会无限期地等待序列里的下一个键，没有办法指定超时。要强制输出一个前缀键，唯一的办法是再绑定一个专门输出该键的按键绑定（例如 `ctrl+a>ctrl+a=text:foo`），或者按一个未绑定的键，它会把两个键都发给程序。
        \\
        \\  * 如果在序列进行中按下了未绑定的键，并且存在一个会 `ignore` 输入的 `catch_all` 绑定，整个序列就被丢弃，什么也不发生。否则，整个序列会被编码并发给运行中的程序，就好像没有这个按键绑定一样。
        \\
        \\  * 如果序列的前缀之前已经绑定过，序列会覆盖之前的绑定。例如，如果 `ctrl+a` 绑定到 `new_window`，`ctrl+a>n` 绑定到 `new_tab`，那么按下 `ctrl+a` 什么也不做。
        \\
        \\  * 补充上一条：如果之前绑定过的序列前缀被用在一个新的、非序列的绑定里，之前绑定的整个序列都会被解除。例如，你绑定了 `ctrl+a>n` 和 `ctrl+a>t`，然后又直接绑定 `ctrl+a`，那么 `ctrl+a>n` 和 `ctrl+a>t` 都会被解除。
        \\
        \\  * 带 `global:` 或 `all:` 前缀的触发键不允许使用触发序列。这是一个我们将来可能去掉的限制。
        \\
        \\动作是满足触发条件时要执行的操作。格式是 `action` 或 `action:param`。后一种形式只在动作需要参数时才有效。
        \\
        \\  * `ignore`：什么都不做，忽略这次按键输入。可以用来把某些输入“吞掉”，让它们不起作用。
        \\
        \\  * `unbind`：删除这个绑定。这会去掉之前的动作；如果这个键是可打印的，会把它传给子命令。Unbind 会删除任何匹配的触发键，包括带 `physical:` 前缀的触发键，无需写出前缀。
        \\
        \\  * `csi:text`：发送一个 CSI 序列。例如 `csi:A` 发送“光标上移”。
        \\
        \\  * `esc:text`：发送一个转义序列。例如 `esc:d` 删除到右侧单词的末尾。
        \\
        \\  * `text:text`：发送一个字符串。使用 Zig 字符串字面量语法。例如 `text:\x15` 发送 Ctrl-U。
        \\
        \\  * 其他所有动作，可在文档中查到，或用 `ghostty +list-actions` 命令查看。
        \\
        \\关于动作的一些说明：
        \\
        \\  * 参数取 `:` 之后的原样内容。双引号或其他机制都会原样包含在内，**不会**被解析。如果你想发送包含空格的字符串值，就用双引号把整个触发键/动作包起来。示例：`--keybind="up=csi:A B"`
        \\
        \\按键绑定还可以指定一些额外的特殊值：
        \\
        \\  * `keybind=clear` 会清除所有已设置的按键绑定。警告：这会删除到此为止的**所有**按键绑定，包括默认的按键绑定。
        \\
        \\按键绑定的触发键前面可以加一些特殊前缀，改变按键绑定的行为。它们是：
        \\
        \\ * `all:`
        \\
        \\   让按键绑定作用于所有终端。默认情况下，按键绑定只作用于获得焦点的终端。设了这个前缀，按键绑定会发给所有终端。这只适用于针对单个终端的动作。对于本来就是全局的动作（例如 `quit`），这个前缀不起作用。
        \\
        \\   自 1.0.0 起可用
        \\
        \\ * `global:`
        \\
        \\   让按键绑定成为全局的。默认情况下，按键绑定只在 Ghostty 内、在合适的条件下（应用获得焦点，有时还要终端获得焦点等）才起作用。如果你想让按键绑定在整个系统范围内起作用（例如即使 Ghostty 没有焦点），就加这个前缀。这个前缀隐含 `all:`。
        \\
        \\   注意：这不是在所有环境下都能用；更多信息见下面的补充说明。
        \\
        \\   自 macOS 1.0.0、GTK 1.2.0 起可用
        \\
        \\ * `unconsumed:`
        \\
        \\   不消耗输入。默认情况下，按键绑定会消耗输入，也就是说相应的编码（如果有）不会发给终端里运行的程序。如果你希望把编码后的值发给程序，就在整个按键绑定前加 `unconsumed:` 前缀。例如：`unconsumed:ctrl+a=reload_config`。带 `global:` 和 `all:` 前缀的按键绑定，不管这项怎么设，总是会消耗输入。因为它们不属于某个特定的终端，所以从不会被编码。
        \\
        \\   自 1.0.0 起可用
        \\
        \\ * `performable:`
        \\
        \\   只有在动作能够执行时才消耗输入。例如，`copy_to_clipboard` 动作只有在有选区可复制时才消耗输入。没有选区时，Ghostty 的表现就像没有设这个按键绑定一样。对带 `global:` 或 `all:` 前缀的按键绑定不起作用。对于按键序列，如果动作不能执行，会重置序列（和完全没有设按键绑定的表现相同）。
        \\
        \\   performable 按键绑定不会作为菜单快捷键出现在应用菜单里。这是因为菜单快捷键会强制执行动作，不管终端处于什么状态。performable 按键绑定照样有效，只是不会作为快捷键标签出现在菜单里。
        \\
        \\   自 1.1.0 起可用
        \\
        \\按键绑定的触发键不按前缀组合区分。例如，`ctrl+a` 和 `global:ctrl+a` 不是两个独立的按键绑定。后设的会覆盖先设的。这个例子里，用的是 `global:` 那个按键绑定。
        \\
        \\可以同时指定多个前缀。例如，`global:unconsumed:ctrl+a=reload_config` 会让这个按键绑定成为全局的，并且在重新加载配置时不消耗输入。
        \\
        \\在 macOS 上，这个功能需要给 Ghostty 授予辅助功能权限。设了 `global:` 按键绑定后，Ghostty 启动或重新加载时会尝试请求这些权限。没有授予权限，按键绑定就不起作用。在 macOS 上，这些权限在“系统设置 -> 隐私与安全性 -> 辅助功能”里。
        \\
        \\自 Ghostty 1.4.0 起，Linux 上的全局快捷键主要通过 [`vicinae-hotkey-v1`](https://github.com/vicinaehq/vicinae-wayland-protocols/tree/main/staging/vicinae-hotkey) 协议支持，以下 Wayland 合成器和桌面环境开箱即用：
        \\
        \\  - Hyprland 0.56.0 起
        \\
        \\在 X11 上，或者你的 Wayland 合成器/桌面环境不支持 `vicinae-hotkey-v1` 时，改用应用广泛得多的 [XDG Global Shortcuts](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html) 协议。
        \\
        \\注意：XDG Global Shortcuts 依赖一个能正常工作的、**为你的桌面环境或合成器设计的** XDG Desktop Portal 实现。请确认装的是正确的那一个。
        \\
        \\已知支持 XDG Global Shortcuts 协议的桌面环境包括：
        \\
        \\ - KDE Plasma [5.27](https://kde.org/announcements/plasma/5/5.27.0/#wayland) 起，需装 `xdg-desktop-portal-kde`
        \\
        \\ - GNOME [48](https://release.gnome.org/48/#and-thats-not-all) 起，需装 `xdg-desktop-portal-gnome`
        \\
        \\ - Hyprland 0.56.0 之前的版本，需装 `xdg-desktop-portal-hyprland`。**需要一些手动配置。** 请参照 [Hyprland Wiki](https://wiki.hypr.land/Configuring/Basics/Binds/#dbus-global-shortcuts) 上列出的步骤，正确设置基于 D-Bus 的全局快捷键。
        \\
        \\两种协议都不实现的桌面环境和合成器不支持全局快捷键，例如基于 wlroots 的合成器 Sway（见 [上游 issue](https://github.com/emersion/xdg-desktop-portal-wlr/issues/240)）和 COSMIC。
        \\
        \\## 链式动作
        \\
        \\一个按键绑定可以用 `chain` 关键字为后续动作设置多个动作。按键绑定被触发时，所有链式动作按顺序执行。语法如下：
        \\
        \\```ini
        \\keybind = ctrl+a=new_window
        \\keybind = chain=goto_split:left
        \\```
        \\
        \\这会把 `ctrl+a` 绑定为先打开一个新窗口，再把焦点移到左边的分屏。每一条 `chain` 都把一个动作追加到最近定义的那个按键绑定上。你可以链接任意多个动作：
        \\
        \\```ini
        \\keybind = ctrl+a=new_window
        \\keybind = chain=goto_split:left
        \\keybind = chain=toggle_fullscreen
        \\```
        \\
        \\链式动作不能带 `global:` 或 `unconsumed:` 之类的前缀。原按键绑定的标志作用于整条链。
        \\
        \\链式动作也适用于按键序列。例如：
        \\
        \\```ini
        \\keybind = ctrl+a>n=new_window
        \\keybind = chain=goto_split:left
        \\````
        \\
        \\带按键序列的链，作用于序列里最近的那个绑定。
        \\
        \\链式按键绑定自 Ghostty 1.3.0 起可用。
        \\
        \\## 按键表
        \\
        \\你还可以创建一组有名字的按键绑定，称为“按键表”。按键表必须被明确激活，里面的绑定才会生效。可以用来实现“复制模式”“vim 模式”之类的功能。一般而言，它可以实现模态的键盘输入。
        \\
        \\按键表用 `<table>/<binding>` 语法定义。`<binding>` 的值就是上面为按键绑定写的全部内容。`<table>` 的值是按键表的名字。表名可以包含除 `/`、`=`、`+` 和 `>` 以外的任何字符。字符 `+` 和 `>` 是为按键绑定语法（修饰键组合和按键序列）保留的。例如 `foo/ctrl+a=new_window` 在名为 `foo` 的表里定义了一个绑定。
        \\
        \\按键表用绑定动作 `activate_key_table:<name>` 和 `deactivate_key_table` 来激活和停用。还有其他与按键表相关的绑定动作；完整列表见文档。这些是使用按键表的主要方式。
        \\
        \\查找绑定时从最内层的表向外进行，所以默认表里的按键绑定始终可用，除非在内层的表里被明确解除。
        \\
        \\按键表有一些特殊的语法和处理：
        \\
        \\  * `<name>/`（不带绑定）定义并清空一个表，重置它的所有按键绑定和设置。
        \\
        \\  * 不能激活一个已经是最内层的表；这样的尝试会被忽略。不过，同一个表只要不是最内层，就可以在栈里出现多次（例如 `A -> B -> A -> B` 有效，而 `A -> B -> B` 无效）。
        \\
        \\  * 可以用 `activate_key_table_once:<name>` 以一次性模式激活一个表。一次性表在任何非 catch-all 绑定被触发时自动停用。
        \\
        \\  * 按键序列在表里也有效：`foo/ctrl+a>ctrl+b=new_window`。如果按了无效的键，序列结束，但表仍然处于激活状态。
        \\
        \\  * 链式动作在表里也有效，`chain` 关键字作用于表里最近定义的那个绑定。例如设了 `table/ctrl+a=new_window`，就可以用 `chain=text:hello` 来链接。重要：chain 本身不带表名前缀，因为它作用于任何表里最近的那个绑定。
        \\
        \\  * `global:` 之类的前缀在表里也有效：`foo/global:ctrl+a=new_window`。
        \\
        \\按键表自 Ghostty 1.3.0 起可用。
        ,
    },
    .{
        .key = .@"key-remap",
        .en = "Remap modifier keys within Ghostty. This allows you to swap or reassign modifier keys at the application level without affecting system-wide settings.",
        .zh = "在 Ghostty 内部重映射修饰键。可在应用层面交换或重新分配修饰键，而不影响系统全局设置。",
        .full_en =
        \\Remap modifier keys within Ghostty. This allows you to swap or reassign
        \\modifier keys at the application level without affecting system-wide
        \\settings.
        \\
        \\The format is `from=to` where both `from` and `to` are modifier key names.
        \\You can use generic names like `ctrl`, `alt`, `shift`, `super` (macOS:
        \\`cmd`/`command`) or sided names like `left_ctrl`, `right_alt`, etc.
        \\
        \\This will NOT change keyboard layout or key encodings outside of Ghostty.
        \\For example, on macOS, `option+a` may still produce `å` even if `option` is
        \\remapped to `ctrl`. Desktop environments usually handle key layout long
        \\before Ghostty receives the key events.
        \\
        \\Example:
        \\
        \\    key-remap = ctrl=super
        \\    key-remap = left_control=right_alt
        \\
        \\Important notes:
        \\
        \\* This is a one-way remap. If you remap `ctrl=super`, then the physical
        \\  Ctrl key acts as Super, but the Super key remains Super.
        \\
        \\* Remaps are not transitive. If you remap `ctrl=super` and `alt=ctrl`,
        \\  pressing Alt will produce Ctrl, NOT Super.
        \\
        \\* This affects both keybind matching and terminal input encoding.
        \\  This does NOT impact keyboard layout or how keys are interpreted
        \\  prior to Ghostty receiving them. For example, `option+a` on macOS
        \\  may still produce `å` even if `option` is remapped to `ctrl`.
        \\
        \\* Generic modifiers (e.g. `ctrl`) match both left and right physical keys.
        \\  Use sided names (e.g. `left_ctrl`) to remap only one side.
        \\
        \\There are other edge case scenarios that may not behave as expected
        \\but are working as intended the way this feature is designed:
        \\
        \\* On macOS, bindings in the main menu will trigger before any remapping
        \\  is done. This is because macOS itself handles menu activation and
        \\  this happens before Ghostty receives the key event. To workaround
        \\  this, you should unbind the menu items and rebind them using your
        \\  desired modifier.
        \\
        \\This configuration can be repeated to specify multiple remaps.
        ,
        .full_zh =
        \\在 Ghostty 内部重映射修饰键。可在应用层面交换或重新分配修饰键，而不影响系统全局设置。
        \\
        \\格式是 `from=to`，`from` 和 `to` 都是修饰键名。可以用 `ctrl`、`alt`、`shift`、`super`（macOS 上为 `cmd`/`command`）这样的通用名，也可以用 `left_ctrl`、`right_alt` 这样带左右的名字。
        \\
        \\这**不会**改变 Ghostty 以外的键盘布局或按键编码。例如在 macOS 上，即使 `option` 被重映射为 `ctrl`，`option+a` 仍然可能产生 `å`。桌面环境通常早在 Ghostty 收到按键事件之前就处理了键盘布局。
        \\
        \\示例：
        \\
        \\    key-remap = ctrl=super
        \\    key-remap = left_control=right_alt
        \\
        \\重要说明：
        \\
        \\* 这是单向的重映射。如果你重映射了 `ctrl=super`，物理 Ctrl 键会当作 Super，但 Super 键仍然是 Super。
        \\
        \\* 重映射不传递。如果你重映射了 `ctrl=super` 和 `alt=ctrl`，按 Alt 产生的是 Ctrl，**不是** Super。
        \\
        \\* 这同时影响按键绑定的匹配和终端输入的编码。它**不**影响键盘布局，也不影响 Ghostty 收到按键之前按键是怎么被解释的。例如在 macOS 上，即使 `option` 被重映射为 `ctrl`，`option+a` 仍然可能产生 `å`。
        \\
        \\* 通用修饰键（例如 `ctrl`）同时匹配左右两个物理键。用带左右的名字（例如 `left_ctrl`）只重映射一侧。
        \\
        \\还有一些边界情况，表现可能和预期不同，但按这个功能的设计，它们是正常的：
        \\
        \\* 在 macOS 上，主菜单里的绑定会在任何重映射之前触发。这是因为菜单的激活由 macOS 自己处理，而且发生在 Ghostty 收到按键事件之前。要绕开这一点，你应该解除这些菜单项的绑定，再用你想要的修饰键重新绑定。
        \\
        \\这项配置可以重复，以指定多个重映射。
        ,
    },
    .{
        .key = .@"window-padding-x",
        .en = "Horizontal window padding. This applies padding between the terminal cells and the left and right window borders. The value is in points, meaning that it will be scaled appropriately for screen DPI.",
        .zh = "窗口的水平内边距。指终端单元格与窗口左右边框之间的空白。单位是点，会按屏幕 DPI 适当缩放。",
        .full_en =
        \\Horizontal window padding. This applies padding between the terminal cells
        \\and the left and right window borders. The value is in points, meaning that
        \\it will be scaled appropriately for screen DPI.
        \\
        \\If this value is set too large, the screen will render nothing, because the
        \\grid will be completely squished by the padding. It is up to you as the user
        \\to pick a reasonable value. If you pick an unreasonable value, a warning
        \\will appear in the logs.
        \\
        \\Changing this configuration at runtime will only affect new terminals, i.e.
        \\new windows, tabs, etc.
        \\
        \\To set a different left and right padding, specify two numerical values
        \\separated by a comma. For example, `window-padding-x = 2,4` will set the
        \\left padding to 2 and the right padding to 4. If you want to set both
        \\paddings to the same value, you can use a single value. For example,
        \\`window-padding-x = 2` will set both paddings to 2.
        ,
        .full_zh =
        \\窗口的水平内边距。指终端单元格与窗口左右边框之间的空白。单位是点，会按屏幕 DPI 适当缩放。
        \\
        \\如果这个值设得太大，屏幕上什么都不会显示，因为网格会被内边距完全挤没。选一个合理的值是你作为用户的事。如果你选了一个不合理的值，日志里会出现警告。
        \\
        \\在运行时修改这项配置，只影响新的终端，即新窗口、新标签页等。
        \\
        \\要分别设置左右内边距，就写两个用逗号分隔的数值。例如，`window-padding-x = 2,4` 会把左内边距设为 2，右内边距设为 4。如果想把两边设成一样，可以只写一个值。例如，`window-padding-x = 2` 会把两边都设为 2。
        ,
    },
    .{
        .key = .@"window-padding-y",
        .en = "Vertical window padding. This applies padding between the terminal cells and the top and bottom window borders. The value is in points, meaning that it will be scaled appropriately for screen DPI.",
        .zh = "窗口的垂直内边距。指终端单元格与窗口上下边框之间的空白。单位是点，会按屏幕 DPI 适当缩放。",
        .full_en =
        \\Vertical window padding. This applies padding between the terminal cells and
        \\the top and bottom window borders. The value is in points, meaning that it
        \\will be scaled appropriately for screen DPI.
        \\
        \\If this value is set too large, the screen will render nothing, because the
        \\grid will be completely squished by the padding. It is up to you as the user
        \\to pick a reasonable value. If you pick an unreasonable value, a warning
        \\will appear in the logs.
        \\
        \\Changing this configuration at runtime will only affect new terminals,
        \\i.e. new windows, tabs, etc.
        \\
        \\To set a different top and bottom padding, specify two numerical values
        \\separated by a comma. For example, `window-padding-y = 2,4` will set the
        \\top padding to 2 and the bottom padding to 4. If you want to set both
        \\paddings to the same value, you can use a single value. For example,
        \\`window-padding-y = 2` will set both paddings to 2.
        ,
        .full_zh =
        \\窗口的垂直内边距。指终端单元格与窗口上下边框之间的空白。单位是点，会按屏幕 DPI 适当缩放。
        \\
        \\如果这个值设得太大，屏幕上什么都不会显示，因为网格会被内边距完全挤没。选一个合理的值是你作为用户的事。如果你选了一个不合理的值，日志里会出现警告。
        \\
        \\在运行时修改这项配置，只影响新的终端，即新窗口、新标签页等。
        \\
        \\要分别设置上下内边距，就写两个用逗号分隔的数值。例如，`window-padding-y = 2,4` 会把上内边距设为 2，下内边距设为 4。如果想把两边设成一样，可以只写一个值。例如，`window-padding-y = 2` 会把两边都设为 2。
        ,
    },
    .{
        .key = .@"window-padding-balance",
        .en = "The viewport dimensions are usually not perfectly divisible by the cell size. In this case, some extra padding on the end of a column and the bottom of the final row may exist. If this is `true`, then this extra padding is automatically balanced between all four edges to minimize imbalance on one side. If this is `false`, the top left grid cell will always hug the edge with zero padding other than what may be specified with the other `window-padding` options.",
        .zh = "可视区域的尺寸通常不能被单元格大小整除，因此一列的末尾和最后一行的底部可能留有多余的空白。设为 `true` 时，这些多余空白会自动平均分到四条边，尽量减少一侧偏多。设为 `false` 时，左上角的单元格总是紧贴边缘，内边距只有其他 `window-padding` 选项指定的那些。",
        .full_en =
        \\The viewport dimensions are usually not perfectly divisible by the cell
        \\size. In this case, some extra padding on the end of a column and the bottom
        \\of the final row may exist. If this is `true`, then this extra padding
        \\is automatically balanced between all four edges to minimize imbalance on
        \\one side. If this is `false`, the top left grid cell will always hug the
        \\edge with zero padding other than what may be specified with the other
        \\`window-padding` options.
        \\
        \\If other `window-padding` fields are set and this is `true`, this will still
        \\apply. The other padding is applied first and may affect how many grid cells
        \\actually exist, and this is applied last in order to balance the padding
        \\given a certain viewport size and grid cell size.
        \\
        \\Valid values are:
        \\
        \\* `false` - No balancing is applied.
        \\* `true` - Balance the padding, but cap the top padding to avoid
        \\  excessive space above the first row. Any excess is shifted to the
        \\  bottom.
        \\* `equal` - Balance the padding equally on all sides without any
        \\  top-padding cap. (Available since: 1.4.0)
        ,
        .full_zh =
        \\可视区域的尺寸通常不能被单元格大小整除，因此一列的末尾和最后一行的底部可能留有多余的空白。设为 `true` 时，这些多余空白会自动平均分到四条边，尽量减少一侧偏多。设为 `false` 时，左上角的单元格总是紧贴边缘，内边距只有其他 `window-padding` 选项指定的那些。
        \\
        \\如果设了其他 `window-padding` 字段，而这项为 `true`，它仍然生效。其他内边距先应用，可能影响实际有多少个网格单元格；这一项最后应用，以便在给定的可视区域大小和单元格大小下平衡内边距。
        \\
        \\有效值：
        \\
        \\* `false`：不做平衡。
        \\* `true`：平衡内边距，但限制顶部内边距，避免第一行上方空出太多。多出的部分移到底部。
        \\* `equal`：在四边平均分配内边距，不限制顶部内边距。（自 1.4.0 起可用）
        ,
    },
    .{
        .key = .@"window-padding-color",
        .en = "The color of the padding area of the window. Valid values are:",
        .zh = "窗口内边距区域的颜色。有效值为：",
        .full_en =
        \\The color of the padding area of the window. Valid values are:
        \\
        \\* `background` - The background color specified in `background`.
        \\* `extend` - Extend the background color of the nearest grid cell.
        \\* `extend-always` - Same as "extend" but always extends without applying
        \\  any of the heuristics that disable extending noted below.
        \\
        \\The "extend" value will be disabled in certain scenarios. On primary
        \\screen applications (e.g. not something like Neovim), the color will not
        \\be extended vertically if any of the following are true:
        \\
        \\* The nearest row has any cells that have the default background color.
        \\  The thinking is that in this case, the default background color looks
        \\  fine as a padding color.
        \\* The nearest row is a prompt row (requires shell integration). The
        \\  thinking here is that prompts often contain powerline glyphs that
        \\  do not look good extended.
        \\* The nearest row contains a perfect fit powerline character. These
        \\  don't look good extended.
        ,
        .full_zh =
        \\窗口内边距区域的颜色。有效值为：
        \\
        \\* `background`：`background` 指定的背景色。
        \\* `extend`：延伸最近的网格单元格的背景色。
        \\* `extend-always`：与 "extend" 相同，但总是延伸，不应用下面提到的、会停用延伸的任何判断。
        \\
        \\"extend" 在某些情况下会被停用。对于主屏幕上的程序（也就是说不是 Neovim 那样的程序），只要下面任何一条成立，颜色就不会在垂直方向上延伸：
        \\
        \\* 最近的那一行里有任何单元格使用默认背景色。理由是这种情况下，默认背景色作为内边距颜色看起来就很好。
        \\* 最近的那一行是提示符行（需要 shell 集成）。理由是提示符里经常有 powerline 字形，延伸后不好看。
        \\* 最近的那一行里有正好铺满的 powerline 字符。它们延伸后不好看。
        ,
    },
    .{
        .key = .@"window-vsync",
        .en = "Synchronize rendering with the screen refresh rate. If true, this will minimize tearing and align redraws with the screen but may cause input latency. If false, this will maximize redraw frequency but may cause tearing, and under heavy load may use more CPU and power.",
        .zh = "让渲染与屏幕刷新率同步。设为 true 时，可减少画面撕裂并使重绘与屏幕对齐，但可能带来输入延迟。设为 false 时，重绘频率最高，但可能画面撕裂，并且在高负载下可能占用更多 CPU 和电量。",
        .full_en =
        \\Synchronize rendering with the screen refresh rate. If true, this will
        \\minimize tearing and align redraws with the screen but may cause input
        \\latency. If false, this will maximize redraw frequency but may cause tearing,
        \\and under heavy load may use more CPU and power.
        \\
        \\This defaults to true because out-of-sync rendering on macOS can
        \\cause kernel panics (macOS 14.4+) and performance issues for external
        \\displays over some hardware such as DisplayLink. If you want to minimize
        \\input latency, set this to false with the known aforementioned risks.
        \\
        \\Changing this value at runtime will only affect new terminals.
        \\
        \\This setting is only supported currently on macOS.
        ,
        .full_zh =
        \\让渲染与屏幕刷新率同步。设为 true 时，可减少画面撕裂并使重绘与屏幕对齐，但可能带来输入延迟。设为 false 时，重绘频率最高，但可能画面撕裂，并且在高负载下可能占用更多 CPU 和电量。
        \\
        \\默认为 true，因为在 macOS 上不同步的渲染可能导致内核崩溃（macOS 14.4+），以及通过 DisplayLink 等某些硬件连接的外接显示器出现性能问题。如果你想尽量减少输入延迟，在清楚上述风险的前提下把它设为 false。
        \\
        \\在运行时修改这个值，只影响新的终端。
        \\
        \\这项设置目前只在 macOS 上支持。
        ,
    },
    .{ .key = .@"window-inherit-working-directory", .en = "If true, new windows will inherit the working directory of the previously focused window. If no window was previously focused, the default working directory will be used (the `working-directory` option).", .zh = "设为 true 时，新窗口继承上一个获得焦点的窗口的工作目录。如果之前没有窗口获得过焦点，则使用默认工作目录（`working-directory` 选项）。" },
    .{ .key = .@"tab-inherit-working-directory", .en = "If true, new tabs will inherit the working directory of the previously focused tab. If no tab was previously focused, the default working directory will be used (the `working-directory` option).", .zh = "设为 true 时，新标签页继承上一个获得焦点的标签页的工作目录。如果之前没有标签页获得过焦点，则使用默认工作目录（`working-directory` 选项）。" },
    .{ .key = .@"split-inherit-working-directory", .en = "If true, new split panes will inherit the working directory of the previously focused split. If no split was previously focused, the default working directory will be used (the `working-directory` option).", .zh = "设为 true 时，新分屏继承上一个获得焦点的分屏的工作目录。如果之前没有分屏获得过焦点，则使用默认工作目录（`working-directory` 选项）。" },
    .{ .key = .@"window-inherit-font-size", .en = "If true, new windows and tabs will inherit the font size of the previously focused window. If no window was previously focused, the default font size will be used. If this is false, the default font size specified in the configuration `font-size` will be used.", .zh = "设为 true 时，新窗口和新标签页继承上一个获得焦点的窗口的字号。如果之前没有窗口获得过焦点，则使用默认字号。设为 false 时，使用配置项 `font-size` 指定的默认字号。" },
    .{
        .key = .@"window-decoration",
        .en = "Configure a preference for window decorations. This setting specifies a _preference_; the actual OS, desktop environment, window manager, etc. may override this preference. Ghostty will do its best to respect this preference but it may not always be possible.",
        .zh = "设置对窗口装饰的偏好。这里指定的是一个偏好；实际的操作系统、桌面环境、窗口管理器等可能会覆盖它。Ghostty 会尽量遵循，但不一定总能做到。",
        .full_en =
        \\Configure a preference for window decorations. This setting specifies
        \\a _preference_; the actual OS, desktop environment, window manager, etc.
        \\may override this preference. Ghostty will do its best to respect this
        \\preference but it may not always be possible.
        \\
        \\Valid values:
        \\
        \\ * `none`
        \\
        \\   All window decorations will be disabled. Titlebar, borders, etc. will
        \\   not be shown. On macOS, this will also disable tabs (enforced by the
        \\   system).
        \\
        \\ * `auto`
        \\
        \\   Automatically decide to use either client-side or server-side
        \\   decorations based on the detected preferences of the current OS and
        \\   desktop environment. This option usually makes Ghostty look the most
        \\   "native" for your desktop.
        \\
        \\ * `client`
        \\
        \\   Prefer client-side decorations.
        \\
        \\   Available since: 1.1.0
        \\
        \\ * `server`
        \\
        \\   Prefer server-side decorations. This is only relevant on Linux with GTK,
        \\   either on X11, or Wayland on a compositor that supports the
        \\   `org_kde_kwin_server_decoration` protocol (e.g. KDE Plasma, but almost
        \\   any non-GNOME desktop supports this protocol).
        \\
        \\   If `server` is set but the environment doesn't support server-side
        \\   decorations, client-side decorations will be used instead.
        \\
        \\   Available since: 1.1.0
        \\
        \\The default value is `auto`.
        \\
        \\For the sake of backwards compatibility and convenience, this setting also
        \\accepts boolean true and false values. If set to `true`, this is equivalent
        \\to `auto`. If set to `false`, this is equivalent to `none`.
        \\This is convenient for users who live primarily on systems that don't
        \\differentiate between client and server-side decorations (e.g. macOS and
        \\Windows).
        \\
        \\The "toggle_window_decorations" keybind action can be used to create
        \\a keybinding to toggle this setting at runtime.
        \\
        \\macOS: To hide the titlebar without removing the native window borders
        \\       or rounded corners, use `macos-titlebar-style = hidden` instead.
        ,
        .full_zh =
        \\设置对窗口装饰的偏好。这里指定的是一个偏好；实际的操作系统、桌面环境、窗口管理器等可能会覆盖它。Ghostty 会尽量遵循，但不一定总能做到。
        \\
        \\有效值：
        \\
        \\ * `none`
        \\
        \\   停用所有窗口装饰。标题栏、边框等都不显示。在 macOS 上，这还会停用标签页（由系统强制）。
        \\
        \\ * `auto`
        \\
        \\   根据检测到的当前操作系统和桌面环境的偏好，自动决定使用客户端装饰还是服务端装饰。这个选项通常让 Ghostty 在你的桌面上看起来最“原生”。
        \\
        \\ * `client`
        \\
        \\   优先使用客户端装饰。
        \\
        \\   自 1.1.0 起可用
        \\
        \\ * `server`
        \\
        \\   优先使用服务端装饰。只在 Linux 的 GTK 下有意义：X11 上，或者 Wayland 上支持 `org_kde_kwin_server_decoration` 协议的合成器（例如 KDE Plasma，但几乎所有非 GNOME 的桌面都支持这个协议）。
        \\
        \\   如果设了 `server`，但环境不支持服务端装饰，就改用客户端装饰。
        \\
        \\   自 1.1.0 起可用
        \\
        \\默认值是 `auto`。
        \\
        \\为了向后兼容和方便，这项设置也接受布尔值 true 和 false。设为 `true` 等同于 `auto`，设为 `false` 等同于 `none`。这对主要使用不区分客户端和服务端装饰的系统（例如 macOS 和 Windows）的用户很方便。
        \\
        \\可以用 "toggle_window_decorations" 按键绑定动作创建一个快捷键，在运行时切换这项设置。
        \\
        \\macOS：要隐藏标题栏又不去掉原生的窗口边框或圆角，请改用 `macos-titlebar-style = hidden`。
        ,
    },
    .{
        .key = .@"window-title-font-family",
        .en = "The font that will be used for the application's window and tab titles.",
        .zh = "应用窗口标题和标签页标题所用的字体。",
        .full_en =
        \\The font that will be used for the application's window and tab titles.
        \\
        \\If this setting is left unset, the system default font will be used.
        \\
        \\Note: any font available on the system may be used, this font is not
        \\required to be a fixed-width font.
        \\
        \\Available since: 1.0.0 on macOS, 1.1.0 on GTK
        ,
        .full_zh =
        \\应用窗口标题和标签页标题所用的字体。
        \\
        \\不设置时使用系统默认字体。
        \\
        \\注意：系统里任何可用的字体都可以用，这个字体不要求是等宽字体。
        \\
        \\自 macOS 1.0.0、GTK 1.1.0 起可用
        ,
    },
    .{
        .key = .@"window-subtitle",
        .en = "The text that will be displayed in the subtitle of the window. Valid values:",
        .zh = "显示在窗口副标题里的文字。有效值：",
        .full_en =
        \\The text that will be displayed in the subtitle of the window. Valid values:
        \\
        \\  * `false` - Disable the subtitle.
        \\  * `working-directory` - Set the subtitle to the working directory of the
        \\     surface.
        \\
        \\This feature is only supported on GTK.
        \\
        \\Available since: 1.1.0
        ,
        .full_zh =
        \\显示在窗口副标题里的文字。有效值：
        \\
        \\  * `false`：停用副标题。
        \\  * `working-directory`：把副标题设为终端的工作目录。
        \\
        \\这项功能只在 GTK 上支持。
        \\
        \\自 1.1.0 起可用
        ,
    },
    .{
        .key = .@"window-theme",
        .en = "The theme to use for the windows. Valid values:",
        .zh = "窗口使用的主题。有效值：",
        .full_en =
        \\The theme to use for the windows. Valid values:
        \\
        \\  * `auto` - Determine the theme based on the configured terminal
        \\     background color. This has no effect if the "theme" configuration
        \\     has separate light and dark themes. In that case, the behavior
        \\     of "auto" is equivalent to "system".
        \\  * `system` - Use the system theme.
        \\  * `light` - Use the light theme regardless of system theme.
        \\  * `dark` - Use the dark theme regardless of system theme.
        \\  * `ghostty` - Use the background and foreground colors specified in the
        \\    Ghostty configuration. This is only supported on Linux builds.
        \\
        \\On macOS, if `macos-titlebar-style` is `tabs` or `transparent`, the window theme will be
        \\automatically set based on the luminosity of the terminal background color.
        \\This only applies to terminal windows. This setting will still apply to
        \\non-terminal windows within Ghostty.
        \\
        \\This is currently only supported on macOS and Linux.
        ,
        .full_zh =
        \\窗口使用的主题。有效值：
        \\
        \\  * `auto`：根据配置的终端背景色决定主题。如果 "theme" 配置分别设了亮色和暗色主题，这项不起作用；那种情况下 "auto" 的行为等同于 "system"。
        \\  * `system`：使用系统主题。
        \\  * `light`：不管系统主题，使用亮色主题。
        \\  * `dark`：不管系统主题，使用暗色主题。
        \\  * `ghostty`：使用 Ghostty 配置里指定的背景色和前景色。只有 Linux 版本支持。
        \\
        \\在 macOS 上，如果 `macos-titlebar-style` 是 `tabs` 或 `transparent`，窗口主题会根据终端背景色的亮度自动设置。这只适用于终端窗口。这项设置仍然作用于 Ghostty 里的非终端窗口。
        \\
        \\目前只在 macOS 和 Linux 上支持。
        ,
    },
    .{
        .key = .@"window-colorspace",
        .en = "The color space to use when interpreting terminal colors. \"Terminal colors\" refers to colors specified in your configuration and colors produced by direct-color SGR sequences.",
        .zh = "解释终端颜色时使用的色彩空间。“终端颜色”指配置里指定的颜色，以及直接颜色 SGR 序列产生的颜色。",
        .full_en =
        \\The color space to use when interpreting terminal colors. "Terminal colors"
        \\refers to colors specified in your configuration and colors produced by
        \\direct-color SGR sequences.
        \\
        \\Valid values:
        \\
        \\  * `srgb` - Interpret colors in the sRGB color space. This is the default.
        \\  * `display-p3` - Interpret colors in the Display P3 color space.
        \\
        \\This setting is currently only supported on macOS.
        ,
        .full_zh =
        \\解释终端颜色时使用的色彩空间。“终端颜色”指配置里指定的颜色，以及直接颜色 SGR 序列产生的颜色。
        \\
        \\有效值：
        \\
        \\  * `srgb`：在 sRGB 色彩空间里解释颜色。这是默认值。
        \\  * `display-p3`：在 Display P3 色彩空间里解释颜色。
        \\
        \\这项设置目前只在 macOS 上支持。
        ,
    },
    .{
        .key = .@"window-height",
        .en = "The initial window size. This size is in terminal grid cells by default. Both values must be set to take effect. If only one value is set, it is ignored.",
        .zh = "初始窗口大小。默认以终端网格单元格为单位。两个值都设置才生效；只设置一个时会被忽略。",
        .full_en =
        \\The initial window size. This size is in terminal grid cells by default.
        \\Both values must be set to take effect. If only one value is set, it is
        \\ignored.
        \\
        \\We don't currently support specifying a size in pixels but a future change
        \\can enable that. If this isn't specified, the app runtime will determine
        \\some default size.
        \\
        \\Note that the window manager may put limits on the size or override the
        \\size. For example, a tiling window manager may force the window to be a
        \\certain size to fit within the grid. There is nothing Ghostty will do about
        \\this, but it will make an effort.
        \\
        \\Sizes larger than the screen size will be clamped to the screen size.
        \\This can be used to create a maximized-by-default window size.
        \\
        \\This will not affect new tabs, splits, or other nested terminal elements.
        \\This only affects the initial window size of any new window. Changing this
        \\value will not affect the size of the window after it has been created. This
        \\is only used for the initial size.
        \\
        \\BUG: On Linux with GTK, the calculated window size will not properly take
        \\into account window decorations. As a result, the grid dimensions will not
        \\exactly match this configuration. If window decorations are disabled (see
        \\`window-decoration`), then this will work as expected.
        \\
        \\Windows smaller than 10 wide by 4 high are not allowed.
        ,
        .full_zh =
        \\初始窗口大小。默认以终端网格单元格为单位。两个值都设置才生效；只设置一个时会被忽略。
        \\
        \\目前还不支持以像素指定大小，但以后的改动可能支持。不指定时，由应用运行时决定一个默认大小。
        \\
        \\注意窗口管理器可能限制或覆盖这个大小。例如，平铺式窗口管理器可能强制窗口为某个大小以适应网格。Ghostty 对此无能为力，但会尽量争取。
        \\
        \\比屏幕大的尺寸会被限制为屏幕大小。可以借此让窗口默认就是最大化的大小。
        \\
        \\这不影响新标签页、分屏或其他嵌套的终端元素。它只影响任何新窗口的初始大小。修改这个值不会影响窗口创建之后的大小。它只用于初始大小。
        \\
        \\BUG：在 Linux 的 GTK 下，算出的窗口大小没有正确考虑窗口装饰。因此网格尺寸不会和这项配置完全一致。如果停用了窗口装饰（见 `window-decoration`），就会按预期工作。
        \\
        \\不允许小于 10 宽、4 高的窗口。
        ,
    },
    .{
        .key = .@"window-position-x",
        .en = "The starting window position. This position is in pixels and is relative to the top-left corner of the primary monitor. Both values must be set to take effect. If only one value is set, it is ignored.",
        .zh = "窗口的起始位置。单位是像素，相对于主显示器的左上角。两个值都设置才生效；只设置一个时会被忽略。",
        .full_en =
        \\The starting window position. This position is in pixels and is relative
        \\to the top-left corner of the primary monitor. Both values must be set to take
        \\effect. If only one value is set, it is ignored.
        \\
        \\Note that the window manager may put limits on the position or override
        \\the position. For example, a tiling window manager may force the window
        \\to be a certain position to fit within the grid. There is nothing Ghostty
        \\will do about this, but it will make an effort.
        \\
        \\Also note that negative values are also up to the operating system and
        \\window manager. Some window managers may not allow windows to be placed
        \\off-screen.
        \\
        \\Invalid positions are runtime-specific, but generally the positions are
        \\clamped to the nearest valid position.
        \\
        \\On macOS, the window position is relative to the top-left corner of
        \\the visible screen area. This means that if the menu bar is visible, the
        \\window will be placed below the menu bar.
        \\
        \\Note: this is only supported on macOS. The GTK runtime does not support
        \\setting the window position, as windows are only allowed position
        \\themselves in X11 and not Wayland.
        ,
        .full_zh =
        \\窗口的起始位置。单位是像素，相对于主显示器的左上角。两个值都设置才生效；只设置一个时会被忽略。
        \\
        \\注意窗口管理器可能限制或覆盖这个位置。例如，平铺式窗口管理器可能强制窗口在某个位置以适应网格。Ghostty 对此无能为力，但会尽量争取。
        \\
        \\还要注意，负值同样取决于操作系统和窗口管理器。有些窗口管理器可能不允许把窗口放到屏幕外。
        \\
        \\无效的位置怎么处理取决于运行时，但一般会被限制到最近的有效位置。
        \\
        \\在 macOS 上，窗口位置相对于可见屏幕区域的左上角。这意味着如果菜单栏可见，窗口会放在菜单栏下方。
        \\
        \\注意：这只在 macOS 上支持。GTK 运行时不支持设置窗口位置，因为只有 X11 允许窗口自己定位，Wayland 不允许。
        ,
    },
    .{
        .key = .@"window-save-state",
        .en = "Whether to enable saving and restoring window state. Window state includes their position, size, tabs, splits, etc. Some window state requires shell integration, such as preserving working directories. See `shell-integration` for more information.",
        .zh = "是否启用窗口状态的保存与恢复。窗口状态包括位置、大小、标签页、分屏等。某些窗口状态需要 shell 集成，比如保留工作目录。详见 `shell-integration`。",
        .full_en =
        \\Whether to enable saving and restoring window state. Window state includes
        \\their position, size, tabs, splits, etc. Some window state requires shell
        \\integration, such as preserving working directories. See `shell-integration`
        \\for more information.
        \\
        \\There are three valid values for this configuration:
        \\
        \\  * `default` will use the default system behavior. On macOS, this
        \\    will only save state if the application is forcibly terminated
        \\    or if it is configured systemwide via Settings.app.
        \\
        \\  * `never` will never save window state.
        \\
        \\  * `always` will always save window state whenever Ghostty is exited.
        \\
        \\If you change this value to `never` while Ghostty is not running, the next
        \\Ghostty launch will NOT restore the window state.
        \\
        \\If you change this value to `default` while Ghostty is not running and the
        \\previous exit saved state, the next Ghostty launch will still restore the
        \\window state. This is because Ghostty cannot know if the previous exit was
        \\due to a forced save or not (macOS doesn't provide this information).
        \\
        \\If you change this value so that window state is saved while Ghostty is not
        \\running, the previous window state will not be restored because Ghostty only
        \\saves state on exit if this is enabled.
        \\
        \\The default value is `default`.
        \\
        \\This is currently only supported on macOS. This has no effect on Linux.
        ,
        .full_zh =
        \\是否启用窗口状态的保存与恢复。窗口状态包括位置、大小、标签页、分屏等。某些窗口状态需要 shell 集成，比如保留工作目录。详见 `shell-integration`。
        \\
        \\这项配置有三个有效值：
        \\
        \\  * `default` 使用系统默认行为。在 macOS 上，只有在应用被强制终止，或者通过“设置”在系统范围内配置了时，才会保存状态。
        \\
        \\  * `never` 从不保存窗口状态。
        \\
        \\  * `always` 每次 Ghostty 退出时都保存窗口状态。
        \\
        \\如果你在 Ghostty 没运行时把这个值改成 `never`，下次 Ghostty 启动时**不会**恢复窗口状态。
        \\
        \\如果你在 Ghostty 没运行时把这个值改成 `default`，而上次退出时保存了状态，下次 Ghostty 启动时仍会恢复窗口状态。这是因为 Ghostty 无法知道上次退出是否是强制保存的（macOS 不提供这个信息）。
        \\
        \\如果你在 Ghostty 没运行时把这个值改成会保存窗口状态的设置，之前的窗口状态不会被恢复，因为 Ghostty 只有在启用了这项时才会在退出时保存状态。
        \\
        \\默认值是 `default`。
        \\
        \\目前只在 macOS 上支持，在 Linux 上不起作用。
        ,
    },
    .{ .key = .@"window-step-resize", .en = "Resize the window in discrete increments of the focused surface's cell size. If this is disabled, surfaces are resized in pixel increments. Currently only supported on macOS.", .zh = "按当前终端单元格大小的整数倍调整窗口大小。禁用时，终端按像素调整大小。目前只有 macOS 支持。" },
    .{
        .key = .@"window-new-tab-position",
        .en = "The position where new tabs are created. Valid values:",
        .zh = "新标签页创建的位置。有效值：",
        .full_en =
        \\The position where new tabs are created. Valid values:
        \\
        \\  * `current` - Insert the new tab after the currently focused tab,
        \\    or at the end if there are no focused tabs.
        \\
        \\  * `end` - Insert the new tab at the end of the tab list.
        ,
        .full_zh =
        \\新标签页创建的位置。有效值：
        \\
        \\  * `current`：把新标签页插在当前获得焦点的标签页后面；如果没有获得焦点的标签页，就插在末尾。
        \\
        \\  * `end`：把新标签页插在标签列表的末尾。
        ,
    },
    .{
        .key = .@"window-show-tab-bar",
        .en = "Whether to show the tab bar.",
        .zh = "是否显示标签栏。",
        .full_en =
        \\Whether to show the tab bar.
        \\
        \\Valid values:
        \\
        \\ - `always`
        \\
        \\   Always display the tab bar, even when there's only one tab.
        \\
        \\   Available since: 1.2.0
        \\
        \\ - `auto` *(default)*
        \\
        \\   Automatically show and hide the tab bar. The tab bar is only
        \\   shown when there are two or more tabs present.
        \\
        \\ - `never`
        \\
        \\   Never show the tab bar. Tabs are only accessible via the tab
        \\   overview or by keybind actions.
        \\
        \\Currently only supported on Linux (GTK).
        ,
        .full_zh =
        \\是否显示标签栏。
        \\
        \\有效值：
        \\
        \\ - `always`
        \\
        \\   始终显示标签栏，即使只有一个标签页。
        \\
        \\   自 1.2.0 起可用
        \\
        \\ - `auto` *（默认）*
        \\
        \\   自动显示和隐藏标签栏。只有在有两个或更多标签页时才显示标签栏。
        \\
        \\ - `never`
        \\
        \\   从不显示标签栏。只能通过标签页概览或按键绑定动作访问标签页。
        \\
        \\目前只在 Linux（GTK）上支持。
        ,
    },
    .{
        .key = .@"window-titlebar-background",
        .en = "Background color for the window titlebar. This only takes effect if window-theme is set to ghostty. Currently only supported in the GTK app runtime.",
        .zh = "窗口标题栏的背景色。只有 window-theme 设为 ghostty 时才生效。目前只有 GTK 应用运行时支持。",
        .full_en =
        \\Background color for the window titlebar. This only takes effect if
        \\window-theme is set to ghostty. Currently only supported in the GTK app
        \\runtime.
        \\
        \\Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.
        ,
        .full_zh =
        \\窗口标题栏的背景色。只有 window-theme 设为 ghostty 时才生效。目前只有 GTK 应用运行时支持。
        \\
        \\可写成十六进制（`#RRGGBB` 或 `RRGGBB`），或 X11 颜色名。
        ,
    },
    .{
        .key = .@"window-titlebar-foreground",
        .en = "Foreground color for the window titlebar. This only takes effect if window-theme is set to ghostty. Currently only supported in the GTK app runtime.",
        .zh = "窗口标题栏的前景色。只有 window-theme 设为 ghostty 时才生效。目前只有 GTK 应用运行时支持。",
        .full_en =
        \\Foreground color for the window titlebar. This only takes effect if
        \\window-theme is set to ghostty. Currently only supported in the GTK app
        \\runtime.
        \\
        \\Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.
        ,
        .full_zh =
        \\窗口标题栏的前景色。只有 window-theme 设为 ghostty 时才生效。目前只有 GTK 应用运行时支持。
        \\
        \\可写成十六进制（`#RRGGBB` 或 `RRGGBB`），或 X11 颜色名。
        ,
    },
    .{
        .key = .@"drag-handle",
        .en = "Controls when drag handles are shown over splits, allowing splits to be rearranged with mouse controls.",
        .zh = "控制何时在分屏上显示拖动手柄，以便用鼠标重新排列分屏。",
        .full_en =
        \\Controls when drag handles are shown over splits,
        \\allowing splits to be rearranged with mouse controls.
        \\
        \\Valid values:
        \\
        \\ - `always`
        \\
        \\   Always display the drag handle, even when there's only one split.
        \\   Not in the control room: the terminal shown there is never dragged.
        \\
        \\ - `auto` *(default)*
        \\
        \\   The handle is only shown when the tab has two or more splits; a
        \\   tab of one split is moved by dragging the tab itself. On macOS and
        \\   Windows it shows when hovered. The terminal shown in the control
        \\   room never has one.
        \\
        \\ - `never`
        \\
        \\   Never show the drag handle. Splits then cannot be rearranged with
        \\   mouse controls.
        \\
        \\Available since: 1.4.0.
        ,
        .full_zh =
        \\控制何时在分屏上显示拖动手柄，以便用鼠标重新排列分屏。
        \\
        \\有效值：
        \\
        \\ - `always`
        \\
        \\   始终显示拖动手柄，即使只有一个分屏。总控台里除外：在那里显示的终端从不被拖动。
        \\
        \\ - `auto` *（默认）*
        \\
        \\   只有在标签页里有两个或更多分屏时才显示手柄；只有一个分屏的标签页，靠拖动标签页本身来移动。在 macOS 和 Windows 上，悬停时才显示。总控台里显示的终端从来没有手柄。
        \\
        \\ - `never`
        \\
        \\   从不显示拖动手柄。这样分屏就不能用鼠标重新排列。
        \\
        \\自 1.4.0 起可用。
        ,
    },
    .{
        .key = .@"resize-overlay",
        .en = "This controls when resize overlays are shown. Resize overlays are a transient popup that shows the size of the terminal while the surfaces are being resized. The possible options are:",
        .zh = "控制何时显示调整大小的浮层。调整大小浮层是一个临时弹出的提示，在调整终端大小时显示终端的尺寸。可选项为：",
        .full_en =
        \\This controls when resize overlays are shown. Resize overlays are a
        \\transient popup that shows the size of the terminal while the surfaces are
        \\being resized. The possible options are:
        \\
        \\  * `always` - Always show resize overlays.
        \\  * `never` - Never show resize overlays.
        \\  * `after-first` - The resize overlay will not appear when the surface
        \\                    is first created, but will show up if the surface is
        \\                    subsequently resized.
        \\
        \\The default is `after-first`.
        ,
        .full_zh =
        \\控制何时显示调整大小的浮层。调整大小浮层是一个临时弹出的提示，在调整终端大小时显示终端的尺寸。可选项为：
        \\
        \\  * `always`：始终显示调整大小浮层。
        \\  * `never`：从不显示调整大小浮层。
        \\  * `after-first`：终端刚创建时不显示调整大小浮层，之后再调整大小时才显示。
        \\
        \\默认是 `after-first`。
        ,
    },
    .{
        .key = .@"resize-overlay-position",
        .en = "If resize overlays are enabled, this controls the position of the overlay. The possible options are:",
        .zh = "启用调整大小浮层时，控制浮层的位置。可选项为：",
        .full_en =
        \\If resize overlays are enabled, this controls the position of the overlay.
        \\The possible options are:
        \\
        \\  * `center`
        \\  * `top-left`
        \\  * `top-center`
        \\  * `top-right`
        \\  * `bottom-left`
        \\  * `bottom-center`
        \\  * `bottom-right`
        \\
        \\The default is `center`.
        ,
        .full_zh =
        \\启用调整大小浮层时，控制浮层的位置。可选项为：
        \\
        \\  * `center`
        \\  * `top-left`
        \\  * `top-center`
        \\  * `top-right`
        \\  * `bottom-left`
        \\  * `bottom-center`
        \\  * `bottom-right`
        \\
        \\默认是 `center`。
        ,
    },
    .{
        .key = .@"resize-overlay-duration",
        .en = "If resize overlays are enabled, this controls how long the overlay is visible on the screen before it is hidden. The default is ¾ of a second or 750 ms.",
        .zh = "启用调整大小浮层时，控制浮层在屏幕上显示多久后隐藏。默认为 ¾ 秒，即 750 毫秒。",
        .full_en =
        \\If resize overlays are enabled, this controls how long the overlay is
        \\visible on the screen before it is hidden. The default is ¾ of a second or
        \\750 ms.
        \\
        \\The duration is specified as a series of numbers followed by time units.
        \\Whitespace is allowed between numbers and units. Each number and unit will
        \\be added together to form the total duration.
        \\
        \\The allowed time units are as follows:
        \\
        \\  * `y` - 365 SI days, or 8760 hours, or 31536000 seconds. No adjustments
        \\    are made for leap years or leap seconds.
        \\  * `d` - one SI day, or 86400 seconds.
        \\  * `h` - one hour, or 3600 seconds.
        \\  * `m` - one minute, or 60 seconds.
        \\  * `s` - one second.
        \\  * `ms` - one millisecond, or 0.001 second.
        \\  * `us` or `µs` - one microsecond, or 0.000001 second.
        \\  * `ns` - one nanosecond, or 0.000000001 second.
        \\
        \\Examples:
        \\  * `1h30m`
        \\  * `45s`
        \\
        \\Units can be repeated and will be added together. This means that
        \\`1h1h` is equivalent to `2h`. This is confusing and should be avoided.
        \\A future update may disallow this.
        \\
        \\The maximum value is `584y 49w 23h 34m 33s 709ms 551µs 615ns`. Any
        \\value larger than this will be clamped to the maximum value.
        \\
        \\Available since 1.0.0
        ,
        .full_zh =
        \\启用调整大小浮层时，控制浮层在屏幕上显示多久后隐藏。默认为 ¾ 秒，即 750 毫秒。
        \\
        \\时长写成一串数字加时间单位。数字和单位之间可以有空白。每组数字和单位加在一起，得到总时长。
        \\
        \\允许的时间单位如下：
        \\
        \\  * `y`：365 个 SI 日，即 8760 小时或 31536000 秒。不考虑闰年和闰秒。
        \\  * `d`：一个 SI 日，即 86400 秒。
        \\  * `h`：一小时，即 3600 秒。
        \\  * `m`：一分钟，即 60 秒。
        \\  * `s`：一秒。
        \\  * `ms`：一毫秒，即 0.001 秒。
        \\  * `us` 或 `µs`：一微秒，即 0.000001 秒。
        \\  * `ns`：一纳秒，即 0.000000001 秒。
        \\
        \\示例：
        \\  * `1h30m`
        \\  * `45s`
        \\
        \\单位可以重复，会被加在一起。也就是说 `1h1h` 等同于 `2h`。这样写容易混淆，应当避免。以后的版本可能不再允许。
        \\
        \\最大值是 `584y 49w 23h 34m 33s 709ms 551µs 615ns`。超过它的值会被限制为最大值。
        \\
        \\自 1.0.0 起可用
        ,
    },
    .{
        .key = .@"focus-follows-mouse",
        .en = "If true, when there are multiple split panes, the mouse selects the pane that is focused. This only applies to the currently focused window; e.g. mousing over a split in an unfocused window will not focus that split and bring the window to front.",
        .zh = "设为 true 时，有多个分屏的情况下，鼠标所在的分屏获得焦点。这只适用于当前获得焦点的窗口；例如，鼠标移到未获得焦点的窗口里的分屏上，不会让该分屏获得焦点，也不会把窗口提到最前。",
        .full_en =
        \\If true, when there are multiple split panes, the mouse selects the pane
        \\that is focused. This only applies to the currently focused window; e.g.
        \\mousing over a split in an unfocused window will not focus that split
        \\and bring the window to front.
        \\
        \\Default is false.
        ,
        .full_zh =
        \\设为 true 时，有多个分屏的情况下，鼠标所在的分屏获得焦点。这只适用于当前获得焦点的窗口；例如，鼠标移到未获得焦点的窗口里的分屏上，不会让该分屏获得焦点，也不会把窗口提到最前。
        \\
        \\默认为 false。
        ,
    },
    .{
        .key = .@"clipboard-read",
        .en = "Whether to allow programs running in the terminal to read/write to the system clipboard (OSC 52, for googling). The default is to allow clipboard reading after prompting the user and allow writing unconditionally.",
        .zh = "是否允许终端里运行的程序读取或写入系统剪贴板（OSC 52，可搜索了解）。默认是询问用户后允许读取，写入则无条件允许。",
        .full_en =
        \\Whether to allow programs running in the terminal to read/write to the
        \\system clipboard (OSC 52, for googling). The default is to allow clipboard
        \\reading after prompting the user and allow writing unconditionally.
        \\
        \\Valid values are:
        \\
        \\  * `ask`
        \\  * `allow`
        \\  * `deny`
        \\
        ,
        .full_zh =
        \\是否允许终端里运行的程序读取或写入系统剪贴板（OSC 52，可搜索了解）。默认是询问用户后允许读取，写入则无条件允许。
        \\
        \\有效值：
        \\
        \\  * `ask`
        \\  * `allow`
        \\  * `deny`
        \\
        ,
    },
    .{
        .key = .@"clipboard-write-limit-bytes",
        .en = "The maximum size in bytes of a single clipboard write by a program running in the terminal via the Kitty clipboard protocol (OSC 5522). This doesn't apply to OSC 52, which is limited by the maximum length of an escape sequence hardcoded into Ghostty for now.",
        .zh = "终端里运行的程序通过 Kitty 剪贴板协议（OSC 5522）一次写入剪贴板的最大字节数。这不适用于 OSC 52，它目前受 Ghostty 内置的转义序列最大长度限制。",
        .full_en =
        \\The maximum size in bytes of a single clipboard write by a program
        \\running in the terminal via the Kitty clipboard protocol (OSC 5522).
        \\This doesn't apply to OSC 52, which is limited by the maximum length
        \\of an escape sequence hardcoded into Ghostty for now.
        \\
        \\Data beyond the limit fails the entire write with an `EFBIG` status,
        \\discards the transaction, and leaves the clipboard untouched. Later
        \\write-related packets are ignored until a new write begins.
        \\
        \\The data is buffered in memory while the write is in progress, so
        \\this limit bounds how much memory a program can make Ghostty
        \\allocate per write. A future improvement will attempt to spool large
        \\writes to disk.
        \\
        \\The default is 64 MiB, the minimum a conforming implementation must
        \\accept. Set this to `unlimited` to remove the limit, allowing writes
        \\bounded only by available memory. A value of `0` rejects every non-empty
        \\write. To reject clipboard writes entirely, use `clipboard-write = deny`
        \\instead.
        \\
        \\This can be changed at runtime and applies to writes that begin
        \\after the change.
        \\
        \\Available since: 1.4.0
        ,
        .full_zh =
        \\终端里运行的程序通过 Kitty 剪贴板协议（OSC 5522）一次写入剪贴板的最大字节数。这不适用于 OSC 52，它目前受 Ghostty 内置的转义序列最大长度限制。
        \\
        \\超过上限的数据会让整次写入以 `EFBIG` 状态失败，丢弃这次事务，剪贴板保持不变。之后与写入相关的数据包都会被忽略，直到开始一次新的写入。
        \\
        \\写入进行中时数据缓存在内存里，所以这个上限限制了程序每次写入能让 Ghostty 分配多少内存。以后的改进会尝试把大的写入暂存到磁盘。
        \\
        \\默认是 64 MiB，这是符合规范的实现必须接受的最小值。设为 `unlimited` 取消上限，写入大小只受可用内存限制。设为 `0` 会拒绝所有非空的写入。要完全拒绝剪贴板写入，请改用 `clipboard-write = deny`。
        \\
        \\可以在运行时修改，适用于修改之后开始的写入。
        \\
        \\自 1.4.0 起可用
        ,
    },
    .{ .key = .@"clipboard-trim-trailing-spaces", .en = "Trims trailing whitespace on data that is copied to the clipboard. This does not affect data sent to the clipboard via `clipboard-write`. This only applies to trailing whitespace on lines that have other characters. Completely blank lines always have their whitespace trimmed.", .zh = "去掉复制到剪贴板的数据末尾的空白。这不影响通过 `clipboard-write` 发到剪贴板的数据。只作用于含有其他字符的行的末尾空白；完全空白的行，其空白总是会被去掉。" },
    .{ .key = .@"clipboard-paste-protection", .en = "Require confirmation before pasting text that appears unsafe. This helps prevent a \"copy/paste attack\" where a user may accidentally execute unsafe commands by pasting text with newlines.", .zh = "粘贴看起来不安全的文本前要求确认。这有助于防止“复制粘贴攻击”，即用户粘贴带换行的文本时，不小心执行了不安全的命令。" },
    .{ .key = .@"clipboard-paste-bracketed-safe", .en = "If true, bracketed pastes will be considered safe. By default, bracketed pastes are considered safe. \"Bracketed\" pastes are pastes while the running program has bracketed paste mode enabled (a setting set by the running program, not the terminal emulator).", .zh = "设为 true 时，括号式粘贴被视为安全。默认就视为安全。“括号式”粘贴是指运行中的程序启用了括号粘贴模式（这是运行中的程序设置的，不是终端模拟器的设置）时的粘贴。" },
    .{
        .key = .@"clipboard-paste-image",
        .en = "Paste an image that is on the clipboard as the path of a file holding it.",
        .zh = "把剪贴板上的图片粘贴为存放该图片的文件路径。",
        .full_en =
        \\Paste an image that is on the clipboard as the path of a file holding it.
        \\
        \\When a paste finds no text and no files on the clipboard but does find an
        \\image -- a system screenshot, a picture copied out of a browser -- the
        \\image is written to a PNG in `screenshot-directory` and that file's path
        \\is what gets pasted, escaped the way a file dropped onto the terminal is.
        \\Coding agents that take an image by path (Claude Code, Codex) pick it up
        \\as an attachment.
        \\
        \\Text always wins: a clipboard holding both text and an image pastes the
        \\text, exactly as before. Pasting the same image twice writes one file.
        \\
        \\Set this to `false` to get the old behaviour back, byte for byte: a paste
        \\with only an image on the clipboard pastes nothing, and on Windows
        \\`ctrl+v` goes through to the program so it can read the clipboard itself.
        \\
        \\Only implemented on macOS and Windows.
        ,
        .full_zh =
        \\把剪贴板上的图片粘贴为存放该图片的文件路径。
        \\
        \\粘贴时，如果剪贴板上没有文本、也没有文件，却有一张图片（系统截图、从浏览器复制的图片），这张图片会写成 `screenshot-directory` 里的一个 PNG，粘贴进去的是这个文件的路径，转义方式和把文件拖到终端上时一样。按路径接收图片的编程 agent（Claude Code、Codex）会把它当作附件。
        \\
        \\文本总是优先：剪贴板上同时有文本和图片时，粘贴的是文本，和以前完全一样。同一张图片粘贴两次只写一个文件。
        \\
        \\设为 `false`，就逐字节回到以前的行为：剪贴板上只有图片时，粘贴什么都没有；在 Windows 上，`ctrl+v` 会传给程序，让它自己去读剪贴板。
        \\
        \\只在 macOS 和 Windows 上实现。
        ,
    },
    .{
        .key = .@"screenshot-directory",
        .en = "The directory screenshots and pasted clipboard images are written to.",
        .zh = "截图和粘贴的剪贴板图片写入的目录。",
        .full_en =
        \\The directory screenshots and pasted clipboard images are written to.
        \\
        \\Unset, this is `$XDG_STATE_HOME/polter/shots` (on Windows,
        \\`%LOCALAPPDATA%\polter\shots` when `XDG_STATE_HOME` is not set). A
        \\leading `~/` is the home directory. The directory is created on first use,
        \\owner-only where the platform has such a thing.
        \\
        \\Point this inside your project when an agent refuses to read files
        \\outside its workspace.
        \\
        \\Files are named `YYYYMMDD-HHMMSS-mmm.png`, with a `.json` of the same name
        \\beside a screenshot that carries annotations. At launch, files in this
        \\directory **whose names match that pattern** and that are more than seven
        \\days old are deleted. Nothing else in the directory is ever touched, so
        \\it is safe to point this at a directory that holds other things.
        \\
        \\Only implemented on macOS and Windows.
        ,
        .full_zh =
        \\截图和粘贴的剪贴板图片写入的目录。
        \\
        \\不设置时是 `$XDG_STATE_HOME/polter/shots`（在 Windows 上，没有设置 `XDG_STATE_HOME` 时是 `%LOCALAPPDATA%\polter\shots`）。开头的 `~/` 表示主目录。目录在第一次使用时创建，在平台支持的情况下只有所有者可访问。
        \\
        \\如果某个 agent 拒绝读取其工作区以外的文件，就把这项指到你的项目里面。
        \\
        \\文件命名为 `YYYYMMDD-HHMMSS-mmm.png`；带标注的截图旁边还有一个同名的 `.json`。启动时，这个目录里**名字符合这个格式**、且超过七天的文件会被删除。目录里的其他东西从不会被碰，所以把它指到一个放着别的东西的目录也是安全的。
        \\
        \\只在 macOS 和 Windows 上实现。
        ,
    },
    .{
        .key = .@"screenshot-mouse-trigger",
        .en = "The modifier keys that, held while clicking the left mouse button anywhere on screen, take a screenshot -- the second way to start one, for when one hand is already on the mouse. The keyboard way is the `screenshot` keybind action.",
        .zh = "在屏幕任意位置按住这些修饰键并点击鼠标左键，就会截图——这是启动截图的第二种方式，适合一只手已经放在鼠标上的时候。键盘方式是 `screenshot` 按键绑定动作。",
        .full_en =
        \\The modifier keys that, held while clicking the left mouse button
        \\anywhere on screen, take a screenshot -- the second way to start one, for
        \\when one hand is already on the mouse. The keyboard way is the
        \\`screenshot` keybind action.
        \\
        \\The value is modifier names joined with `+`: `shift`, `ctrl` (or
        \\`control`), `alt` (or `opt`, `option`) and `super` (or `cmd`, `command`).
        \\The default is `cmd+shift` on macOS and `ctrl+shift` elsewhere. `none`
        \\turns this off. A value with no modifier in it is refused: it would make
        \\every click on the machine a screenshot.
        \\
        \\The click has to be made with exactly these modifiers held -- one more
        \\and it is some other program's gesture, not this one. It is the press
        \\that counts, not the release.
        \\
        \\The screenshot opens exactly as the keybind opens it: nothing is selected
        \\yet, the window under the pointer is the one in focus, and a second click
        \\selects it. (Until 2026-10-07 the gesture was a double-click and the
        \\window came already selected.)
        \\
        \\On macOS the click is not hidden from the application under the pointer,
        \\so click on something that does not react: with `cmd+shift` held a click
        \\on a link opens it in a new tab, and one in a list extends the selection.
        \\On Windows the click is swallowed -- which also means that while Polter
        \\is running, no other program sees a click made with exactly these
        \\modifiers. Choose another combination, or `none`, to have those back.
        \\
        \\Only implemented on macOS and Windows.
        ,
        .full_zh =
        \\在屏幕任意位置按住这些修饰键并点击鼠标左键，就会截图——这是启动截图的第二种方式，适合一只手已经放在鼠标上的时候。键盘方式是 `screenshot` 按键绑定动作。
        \\
        \\值是用 `+` 连起来的修饰键名：`shift`、`ctrl`（或 `control`）、`alt`（或 `opt`、`option`）和 `super`（或 `cmd`、`command`）。默认在 macOS 上是 `cmd+shift`，其他平台是 `ctrl+shift`。`none` 关闭这个功能。不含任何修饰键的值会被拒绝：那会让机器上的每一次点击都变成截图。
        \\
        \\点击时必须正好按着这些修饰键：多按一个，就是别的程序的手势，不是这个。算数的是按下，不是松开。
        \\
        \\截图打开的方式和按键绑定打开时完全一样：还没有选中任何东西，指针下的窗口获得焦点，再点一下就选中它。（在 2026-10-07 之前，这个手势是双击，窗口会直接被选中。）
        \\
        \\在 macOS 上，这次点击不会对指针下的应用隐藏，所以请点在不会有反应的地方：按着 `cmd+shift` 点链接，会在新标签页里打开它；点列表，会扩展选区。在 Windows 上，这次点击会被吞掉，这也意味着 Polter 运行期间，正好按着这些修饰键的点击，别的程序都收不到。要把它们要回来，就选另一种组合，或者 `none`。
        \\
        \\只在 macOS 和 Windows 上实现。
        ,
    },
    .{
        .key = .@"screenshot-agent-access",
        .en = "Whether an agent running in a Polter terminal may take screenshots.",
        .zh = "在 Polter 终端里运行的 agent 是否可以截图。",
        .full_en =
        \\Whether an agent running in a Polter terminal may take screenshots.
        \\
        \\With `allow`, the default, an agent has the `screenshot_*` tools: it can
        \\list the windows on screen, capture a display, a window or a region,
        \\draw annotations on a screenshot, take a long screenshot, open the
        \\screenshot interface for you, and read what earlier screenshots recorded
        \\about themselves. With `deny` every one of those tools is refused, and
        \\the refusal names this setting.
        \\
        \\What an agent captures goes to a file in `screenshot-directory` and
        \\nowhere else: it is not put on the clipboard and not pasted anywhere.
        \\A terminal you have shielded is never photographed on an agent's behalf
        \\-- its window cannot be the target, and where it is visible in a wider
        \\capture it is painted over.
        \\
        \\This does not affect screenshots you take yourself.
        \\
        \\Only implemented on macOS and Windows.
        ,
        .full_zh =
        \\在 Polter 终端里运行的 agent 是否可以截图。
        \\
        \\设为 `allow`（默认）时，agent 拥有 `screenshot_*` 工具：可以列出屏幕上的窗口，截取一个显示器、一个窗口或一个区域，在截图上画标注，截长图，为你打开截图界面，并读取之前的截图记录下的关于它们自己的信息。设为 `deny` 时，这些工具全部被拒绝，拒绝时会点名这项设置。
        \\
        \\agent 截到的内容只写进 `screenshot-directory` 里的一个文件，不去别的地方：不放进剪贴板，也不粘贴到任何地方。你屏蔽了的终端永远不会被替 agent 拍下来：它的窗口不能作为目标，在更大范围的截图里出现时会被涂掉。
        \\
        \\这不影响你自己截的图。
        \\
        \\只在 macOS 和 Windows 上实现。
        ,
    },
    .{
        .key = .@"title-report",
        .en = "Enables or disabled title reporting (CSI 21 t). This escape sequence allows the running program to query the terminal title. This is a common security issue and is disabled by default.",
        .zh = "启用或禁用标题上报（CSI 21 t）。这个转义序列允许运行中的程序查询终端标题。这是常见的安全问题，默认禁用。",
        .full_en =
        \\Enables or disabled title reporting (CSI 21 t). This escape sequence
        \\allows the running program to query the terminal title. This is a common
        \\security issue and is disabled by default.
        \\
        \\Warning: This can expose sensitive information at best and enable
        \\arbitrary code execution at worst (with a maliciously crafted title
        \\and a minor amount of user interaction).
        \\
        \\Available since: 1.0.1
        ,
        .full_zh =
        \\启用或禁用标题上报（CSI 21 t）。这个转义序列允许运行中的程序查询终端标题。这是常见的安全问题，默认禁用。
        \\
        \\警告：往轻里说，这会暴露敏感信息；往重里说，会让任意代码得以执行（只需一个恶意构造的标题，加上一点用户操作）。
        \\
        \\自 1.0.1 起可用
        ,
    },
    .{
        .key = .@"image-storage-limit",
        .en = "The total amount of bytes that can be used for image data (e.g. the Kitty image protocol) per terminal screen. The maximum value is 4,294,967,295 (4GiB). The default is 320MB. If this is set to zero, then all image protocols will be disabled.",
        .zh = "每个终端屏幕可用于图像数据（如 Kitty 图像协议）的总字节数。最大值为 4,294,967,295（4GiB），默认为 320MB。设为 0 时，所有图像协议都会被禁用。",
        .full_en =
        \\The total amount of bytes that can be used for image data (e.g. the Kitty
        \\image protocol) per terminal screen. The maximum value is 4,294,967,295
        \\(4GiB). The default is 320MB. If this is set to zero, then all image
        \\protocols will be disabled.
        \\
        \\This value is separate for primary and alternate screens so the effective
        \\limit per surface is double.
        ,
        .full_zh =
        \\每个终端屏幕可用于图像数据（如 Kitty 图像协议）的总字节数。最大值为 4,294,967,295（4GiB），默认为 320MB。设为 0 时，所有图像协议都会被禁用。
        \\
        \\这个值对主屏幕和备用屏幕分别计算，所以每个终端实际的上限是它的两倍。
        ,
    },
    .{
        .key = .@"copy-on-select",
        .en = "Whether to automatically copy selected text to the clipboard.",
        .zh = "是否自动把选中的文本复制到剪贴板。",
        .full_en =
        \\Whether to automatically copy selected text to the clipboard.
        \\
        \\Valid values:
        \\
        \\* `none` - Do not copy selected text automatically.
        \\
        \\* `primary` - Copy to the selection clipboard only: the X11/Wayland
        \\  primary selection on Linux, Polter's own selection pasteboard on macOS
        \\  (the one middle-click pastes from). Has no effect on Windows, which has
        \\  no selection clipboard. (Available since: 1.4.0)
        \\
        \\* `clipboard` - Copy text to the system clipboard only.
        \\
        \\* `both` - Copy to both the system clipboard and the selection clipboard;
        \\  only the system clipboard on Windows. (Available since: 1.4.0)
        \\
        \\For backward compatibility and convenience, a value of `true` is the same as
        \\`primary` on Linux and macOS and `clipboard` on Windows (what `true` did
        \\before 1.4 on each), and `false` is an alias for `none`.
        \\
        \\The default value is `primary` on Linux and macOS and `none` otherwise.
        \\
        \\⚠️ **Polter keeps macOS at `primary`; upstream changed it to `none`.**
        \\Before 1.4 the default here was `true` on Linux and macOS, and on macOS
        \\`true` went to the selection clipboard because the macOS host declares
        \\`supports_selection_clipboard` (a private pasteboard, which is also what
        \\middle-click pastes from). `primary` is that same behaviour under the new
        \\name, so this keeps what a Polter user on a Mac already has rather than
        \\switching copy-on-select off under them. Windows was `false` and stays
        \\`none`: it has no selection clipboard, so `primary` would do nothing.
        ,
        .full_zh =
        \\是否自动把选中的文本复制到剪贴板。
        \\
        \\有效值：
        \\
        \\* `none`：不自动复制选中的文本。
        \\
        \\* `primary`：只复制到选择剪贴板：Linux 上是 X11/Wayland 的主选择，macOS 上是 Polter 自己的选择粘贴板（中键粘贴的就是它）。在没有选择剪贴板的 Windows 上不起作用。（自 1.4.0 起可用）
        \\
        \\* `clipboard`：只把文本复制到系统剪贴板。
        \\
        \\* `both`：同时复制到系统剪贴板和选择剪贴板；在 Windows 上只复制到系统剪贴板。（自 1.4.0 起可用）
        \\
        \\为了向后兼容和方便，值 `true` 在 Linux 和 macOS 上等同于 `primary`，在 Windows 上等同于 `clipboard`（也就是 1.4 之前 `true` 在各平台上的行为），`false` 是 `none` 的别名。
        \\
        \\默认值在 Linux 和 macOS 上是 `primary`，其他平台是 `none`。
        \\
        \\⚠️ **Polter 在 macOS 上保持 `primary`；上游改成了 `none`。** 1.4 之前，这里的默认值在 Linux 和 macOS 上是 `true`，而在 macOS 上 `true` 会复制到选择剪贴板，因为 macOS 宿主声明了 `supports_selection_clipboard`（一个私有粘贴板，中键粘贴的也是它）。`primary` 就是新名字下的同一个行为，所以这样保留了 Mac 上的 Polter 用户原有的行为，而不是在他们不知情时把选中即复制关掉。Windows 原来是 `false`，现在仍是 `none`：它没有选择剪贴板，所以 `primary` 什么都不会做。
        ,
    },
    .{
        .key = .@"right-click-action",
        .en = "The action to take when the user right-clicks on the terminal surface.",
        .zh = "用户在终端上点击鼠标右键时执行的动作。",
        .full_en =
        \\The action to take when the user right-clicks on the terminal surface.
        \\
        \\Valid values:
        \\  * `context-menu` - Show the context menu.
        \\  * `paste` - Paste the contents of the clipboard.
        \\  * `copy` - Copy the selected text to the clipboard.
        \\  * `copy-or-paste` - If there is a selection, copy the selected text to
        \\     the clipboard; otherwise, paste the contents of the clipboard.
        \\  * `ignore` - Do nothing, ignore the right-click.
        \\
        \\The default value is `context-menu`.
        ,
        .full_zh =
        \\用户在终端上点击鼠标右键时执行的动作。
        \\
        \\有效值：
        \\  * `context-menu`：显示右键菜单。
        \\  * `paste`：粘贴剪贴板的内容。
        \\  * `copy`：把选中的文本复制到剪贴板。
        \\  * `copy-or-paste`：有选区时把选中的文本复制到剪贴板；否则粘贴剪贴板的内容。
        \\  * `ignore`：什么都不做，忽略这次右键点击。
        \\
        \\默认值是 `context-menu`。
        ,
    },
    .{
        .key = .@"middle-click-action",
        .en = "The action to take when the user middle-clicks on the terminal surface.",
        .zh = "用户在终端上点击鼠标中键时执行的动作。",
        .full_en =
        \\The action to take when the user middle-clicks on the terminal surface.
        \\
        \\Valid values:
        \\  * `primary-paste` - Paste from the selection clipboard (Linux, and
        \\     Polter's selection pasteboard on macOS). Does nothing on Windows,
        \\     which has no selection clipboard.
        \\  * `clipboard-paste` - Paste from the system clipboard.
        \\  * `ignore` - Do nothing, ignore the middle click.
        \\
        \\The default value is `primary-paste`, except on Windows where it is
        \\`clipboard-paste`.
        \\
        \\⚠️ **Windows differs from upstream on purpose.** `primary-paste` only acts
        \\when the host has a selection clipboard, and the Windows host does not
        \\(`supports_selection_clipboard: false`). Upstream removed the fallback to
        \\the system clipboard, so with upstream's default a middle click on Windows
        \\would do nothing at all. This is the other half of `Keybinds.init` not
        \\binding `shift+insert` to the selection clipboard on Windows.
        ,
        .full_zh =
        \\用户在终端上点击鼠标中键时执行的动作。
        \\
        \\有效值：
        \\  * `primary-paste`：从选择剪贴板粘贴（Linux 上，以及 macOS 上 Polter 的选择粘贴板）。在没有选择剪贴板的 Windows 上什么都不做。
        \\  * `clipboard-paste`：从系统剪贴板粘贴。
        \\  * `ignore`：什么都不做，忽略这次中键点击。
        \\
        \\默认值是 `primary-paste`，Windows 上是 `clipboard-paste`。
        \\
        \\⚠️ **Windows 有意和上游不同。** `primary-paste` 只在宿主有选择剪贴板时才起作用，而 Windows 宿主没有（`supports_selection_clipboard: false`）。上游去掉了退回系统剪贴板的做法，所以按上游的默认值，Windows 上的中键点击会什么都不做。这和 `Keybinds.init` 在 Windows 上不把 `shift+insert` 绑定到选择剪贴板，是同一件事的两半。
        ,
    },
    .{ .key = .@"click-repeat-interval", .en = "The time in milliseconds between clicks to consider a click a repeat (double, triple, etc.) or an entirely new single click. A value of zero will use a platform-specific default. The default on macOS is determined by the OS settings. On every other platform it is 500ms.", .zh = "两次点击相隔多少毫秒以内，算作重复点击（双击、三击等），否则算全新的单击。设为 0 时使用平台特有的默认值。macOS 上的默认值由系统设置决定，其他平台为 500 毫秒。" },
    .{
        .key = .@"config-file",
        .en = "Additional configuration files to read. This configuration can be repeated to read multiple configuration files. Configuration files themselves can load more configuration files. Paths are relative to the file containing the `config-file` directive. For command-line arguments, paths are relative to the current working directory.",
        .zh = "要额外读取的配置文件。这项配置可重复，以读取多个配置文件。配置文件本身也可以再加载更多配置文件。路径相对于包含该 `config-file` 指令的文件；命令行参数里的路径相对于当前工作目录。",
        .full_en =
        \\Additional configuration files to read. This configuration can be repeated
        \\to read multiple configuration files. Configuration files themselves can
        \\load more configuration files. Paths are relative to the file containing the
        \\`config-file` directive. For command-line arguments, paths are relative to
        \\the current working directory.
        \\
        \\Prepend a ? character to the file path to suppress errors if the file does
        \\not exist. If you want to include a file that begins with a literal ?
        \\character, surround the file path in double quotes (").
        \\
        \\Cycles are not allowed. If a cycle is detected, an error will be logged and
        \\the configuration file will be ignored.
        \\
        \\Configuration files are loaded after the configuration they're defined
        \\within in the order they're defined. **THIS IS A VERY SUBTLE BUT IMPORTANT
        \\POINT.** To put it another way: configuration files do not take effect
        \\until after the entire configuration is loaded. For example, in the
        \\configuration below:
        \\
        \\```
        \\config-file = "foo"
        \\a = 1
        \\```
        \\
        \\If "foo" contains `a = 2`, the final value of `a` will be 2, because
        \\`foo` is loaded after the configuration file that configures the
        \\nested `config-file` value.
        ,
        .full_zh =
        \\要额外读取的配置文件。这项配置可重复，以读取多个配置文件。配置文件本身也可以再加载更多配置文件。路径相对于包含该 `config-file` 指令的文件；命令行参数里的路径相对于当前工作目录。
        \\
        \\在文件路径前加一个 ? 字符，可以在文件不存在时不报错。如果要包含的文件名本身以 ? 字符开头，就用双引号（"）把文件路径包起来。
        \\
        \\不允许循环引用。检测到循环时，会记录一条错误，并忽略这个配置文件。
        \\
        \\配置文件在定义它的那份配置之后加载，按定义的顺序。**这一点非常微妙，但很重要。** 换句话说：配置文件要等整份配置加载完之后才生效。例如，在下面的配置里：
        \\
        \\```
        \\config-file = "foo"
        \\a = 1
        \\```
        \\
        \\如果 "foo" 里写着 `a = 2`，`a` 的最终值是 2，因为 `foo` 是在配置了嵌套 `config-file` 值的那个配置文件之后加载的。
        ,
    },
    .{
        .key = .@"config-default-files",
        .en = "When this is true, the default configuration file paths will be loaded. The default configuration file paths are currently only the XDG config path ($XDG_CONFIG_HOME/ghostty/config.ghostty).",
        .zh = "为 true 时，加载默认配置文件路径。默认配置文件路径目前只有 XDG 配置路径（$XDG_CONFIG_HOME/ghostty/config.ghostty）。",
        .full_en =
        \\When this is true, the default configuration file paths will be loaded.
        \\The default configuration file paths are currently only the XDG
        \\config path ($XDG_CONFIG_HOME/ghostty/config.ghostty).
        \\
        \\If this is false, the default configuration paths will not be loaded.
        \\This is targeted directly at using Ghostty from the CLI in a way
        \\that minimizes external effects.
        \\
        \\This is a CLI-only configuration. Setting this in a configuration file
        \\will have no effect. It is not an error, but it will not do anything.
        \\This configuration can only be set via CLI arguments.
        ,
        .full_zh =
        \\为 true 时，加载默认配置文件路径。默认配置文件路径目前只有 XDG 配置路径（$XDG_CONFIG_HOME/ghostty/config.ghostty）。
        \\
        \\为 false 时，不加载默认配置路径。这是专门为了在命令行上使用 Ghostty 时尽量减少外部影响。
        \\
        \\这是一项只能在命令行上用的配置。在配置文件里设置它不起作用：不会报错，但也不会做任何事。这项配置只能通过命令行参数设置。
        ,
    },
    .{
        .key = .@"confirm-close-surface",
        .en = "Confirms that a surface should be closed before closing it.",
        .zh = "关闭终端前先确认。",
        .full_en =
        \\Confirms that a surface should be closed before closing it.
        \\
        \\This defaults to `true`. If set to `false`, surfaces will close without
        \\any confirmation. This can also be set to `always`, which will always
        \\confirm closing a surface, even if shell integration says a process isn't
        \\running.
        ,
        .full_zh =
        \\关闭终端前先确认。
        \\
        \\默认为 `true`。设为 `false` 时，终端关闭前不做任何确认。也可以设为 `always`，即使 shell 集成表明没有进程在运行，也总是确认关闭。
        ,
    },
    .{
        .key = .@"quit-after-last-window-closed",
        .en = "Whether or not to quit after the last surface is closed.",
        .zh = "最后一个终端关闭后是否退出。",
        .full_en =
        \\Whether or not to quit after the last surface is closed.
        \\
        \\This defaults to `false` on macOS since that is standard behavior for
        \\a macOS application. On Linux, this defaults to `true` since that is
        \\generally expected behavior.
        \\
        \\On Linux, if this is `true`, Ghostty can delay quitting fully until a
        \\configurable amount of time has passed after the last window is closed.
        \\See the documentation of `quit-after-last-window-closed-delay`.
        ,
        .full_zh =
        \\最后一个终端关闭后是否退出。
        \\
        \\在 macOS 上默认为 `false`，因为这是 macOS 应用的标准行为。在 Linux 上默认为 `true`，因为这通常是人们预期的行为。
        \\
        \\在 Linux 上，如果这项为 `true`，Ghostty 可以在最后一个窗口关闭后再等一段可配置的时间才完全退出。见 `quit-after-last-window-closed-delay` 的文档。
        ,
    },
    .{
        .key = .@"quit-after-last-window-closed-delay",
        .en = "Controls how long Ghostty will stay running after the last open surface has been closed. This only has an effect if `quit-after-last-window-closed` is also set to `true`.",
        .zh = "最后一个打开的终端关闭后，Ghostty 继续运行多久。只有 `quit-after-last-window-closed` 也设为 `true` 时才有效。",
        .full_en =
        \\Controls how long Ghostty will stay running after the last open surface has
        \\been closed. This only has an effect if `quit-after-last-window-closed` is
        \\also set to `true`.
        \\
        \\The minimum value for this configuration is `1s`. Any values lower than
        \\this will be clamped to `1s`.
        \\
        \\The duration is specified as a series of numbers followed by time units.
        \\Whitespace is allowed between numbers and units. Each number and unit will
        \\be added together to form the total duration.
        \\
        \\The allowed time units are as follows:
        \\
        \\  * `y` - 365 SI days, or 8760 hours, or 31536000 seconds. No adjustments
        \\    are made for leap years or leap seconds.
        \\  * `d` - one SI day, or 86400 seconds.
        \\  * `h` - one hour, or 3600 seconds.
        \\  * `m` - one minute, or 60 seconds.
        \\  * `s` - one second.
        \\  * `ms` - one millisecond, or 0.001 second.
        \\  * `us` or `µs` - one microsecond, or 0.000001 second.
        \\  * `ns` - one nanosecond, or 0.000000001 second.
        \\
        \\Examples:
        \\  * `1h30m`
        \\  * `45s`
        \\
        \\Units can be repeated and will be added together. This means that
        \\`1h1h` is equivalent to `2h`. This is confusing and should be avoided.
        \\A future update may disallow this.
        \\
        \\The maximum value is `584y 49w 23h 34m 33s 709ms 551µs 615ns`. Any
        \\value larger than this will be clamped to the maximum value.
        \\
        \\By default `quit-after-last-window-closed-delay` is unset and
        \\Ghostty will quit immediately after the last window is closed if
        \\`quit-after-last-window-closed` is `true`.
        \\
        \\Only implemented on Linux.
        ,
        .full_zh =
        \\最后一个打开的终端关闭后，Ghostty 继续运行多久。只有 `quit-after-last-window-closed` 也设为 `true` 时才有效。
        \\
        \\这项配置的最小值是 `1s`。比它小的值会被限制为 `1s`。
        \\
        \\时长写成一串数字加时间单位。数字和单位之间可以有空白。每组数字和单位加在一起，得到总时长。
        \\
        \\允许的时间单位如下：
        \\
        \\  * `y`：365 个 SI 日，即 8760 小时或 31536000 秒。不考虑闰年和闰秒。
        \\  * `d`：一个 SI 日，即 86400 秒。
        \\  * `h`：一小时，即 3600 秒。
        \\  * `m`：一分钟，即 60 秒。
        \\  * `s`：一秒。
        \\  * `ms`：一毫秒，即 0.001 秒。
        \\  * `us` 或 `µs`：一微秒，即 0.000001 秒。
        \\  * `ns`：一纳秒，即 0.000000001 秒。
        \\
        \\示例：
        \\  * `1h30m`
        \\  * `45s`
        \\
        \\单位可以重复，会被加在一起。也就是说 `1h1h` 等同于 `2h`。这样写容易混淆，应当避免。以后的版本可能不再允许。
        \\
        \\最大值是 `584y 49w 23h 34m 33s 709ms 551µs 615ns`。超过它的值会被限制为最大值。
        \\
        \\默认情况下 `quit-after-last-window-closed-delay` 不设置，如果 `quit-after-last-window-closed` 为 `true`，Ghostty 会在最后一个窗口关闭后立即退出。
        \\
        \\只在 Linux 上实现。
        ,
    },
    .{ .key = .@"initial-window", .en = "This controls whether an initial window is created when Ghostty is run. Note that if `quit-after-last-window-closed` is `true` and `quit-after-last-window-closed-delay` is set, setting `initial-window` to `false` will mean that Ghostty will quit after the configured delay if no window is ever created. Only implemented on Linux and macOS.", .zh = "控制运行 Ghostty 时是否创建初始窗口。注意：如果 `quit-after-last-window-closed` 为 `true` 且设置了 `quit-after-last-window-closed-delay`，把 `initial-window` 设为 `false` 意味着，若一直没有创建过窗口，Ghostty 会在配置的延迟后退出。只在 Linux 和 macOS 上实现。" },
    .{
        .key = .@"undo-timeout",
        .en = "The duration that undo operations remain available. After this time, the operation will be removed from the undo stack and cannot be undone.",
        .zh = "撤销操作保持可用的时长。超过这个时间，操作会从撤销栈中移除，无法再撤销。",
        .full_en =
        \\The duration that undo operations remain available. After this
        \\time, the operation will be removed from the undo stack and
        \\cannot be undone.
        \\
        \\The default value is 5 seconds.
        \\
        \\This timeout applies per operation, meaning that if you perform
        \\multiple operations, each operation will have its own timeout.
        \\New operations do not reset the timeout of previous operations.
        \\
        \\A timeout of zero will effectively disable undo operations. It is
        \\not possible to set an infinite timeout, but you can set a very
        \\large timeout to effectively disable the timeout (on the order of years).
        \\This is highly discouraged, as it will cause the undo stack to grow
        \\indefinitely, memory usage to grow unbounded, and terminal sessions
        \\to never actually quit.
        \\
        \\The duration is specified as a series of numbers followed by time units.
        \\Whitespace is allowed between numbers and units. Each number and unit will
        \\be added together to form the total duration.
        \\
        \\The allowed time units are as follows:
        \\
        \\  * `y` - 365 SI days, or 8760 hours, or 31536000 seconds. No adjustments
        \\    are made for leap years or leap seconds.
        \\  * `d` - one SI day, or 86400 seconds.
        \\  * `h` - one hour, or 3600 seconds.
        \\  * `m` - one minute, or 60 seconds.
        \\  * `s` - one second.
        \\  * `ms` - one millisecond, or 0.001 second.
        \\  * `us` or `µs` - one microsecond, or 0.000001 second.
        \\  * `ns` - one nanosecond, or 0.000000001 second.
        \\
        \\Examples:
        \\  * `1h30m`
        \\  * `45s`
        \\
        \\Units can be repeated and will be added together. This means that
        \\`1h1h` is equivalent to `2h`. This is confusing and should be avoided.
        \\A future update may disallow this.
        \\
        \\This configuration is only supported on macOS. Linux doesn't
        \\support undo operations at all so this configuration has no
        \\effect.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\撤销操作保持可用的时长。超过这个时间，操作会从撤销栈中移除，无法再撤销。
        \\
        \\默认值是 5 秒。
        \\
        \\这个超时按每次操作单独计算，也就是说如果你做了多次操作，每次操作都有自己的超时。新的操作不会重置之前操作的超时。
        \\
        \\超时为零实际上会停用撤销操作。不能设置无限的超时，但可以设一个非常大的超时（以年计），实际上相当于取消超时。非常不建议这样做，因为这会让撤销栈无限增长、内存占用不受限制地增长，终端会话也永远不会真正退出。
        \\
        \\时长写成一串数字加时间单位。数字和单位之间可以有空白。每组数字和单位加在一起，得到总时长。
        \\
        \\允许的时间单位如下：
        \\
        \\  * `y`：365 个 SI 日，即 8760 小时或 31536000 秒。不考虑闰年和闰秒。
        \\  * `d`：一个 SI 日，即 86400 秒。
        \\  * `h`：一小时，即 3600 秒。
        \\  * `m`：一分钟，即 60 秒。
        \\  * `s`：一秒。
        \\  * `ms`：一毫秒，即 0.001 秒。
        \\  * `us` 或 `µs`：一微秒，即 0.000001 秒。
        \\  * `ns`：一纳秒，即 0.000000001 秒。
        \\
        \\示例：
        \\  * `1h30m`
        \\  * `45s`
        \\
        \\单位可以重复，会被加在一起。也就是说 `1h1h` 等同于 `2h`。这样写容易混淆，应当避免。以后的版本可能不再允许。
        \\
        \\这项配置只在 macOS 上支持。Linux 完全不支持撤销操作，所以这项配置不起作用。
        \\
        \\自 1.2.0 起可用。
        ,
    },
    .{
        .key = .@"quick-terminal-position",
        .en = "The position of the \"quick\" terminal window. To learn more about the quick terminal, see the documentation for the `toggle_quick_terminal` binding action.",
        .zh = "“快速”终端窗口的位置。关于快速终端，详见 `toggle_quick_terminal` 绑定动作的文档。",
        .full_en =
        \\The position of the "quick" terminal window. To learn more about the
        \\quick terminal, see the documentation for the `toggle_quick_terminal`
        \\binding action.
        \\
        \\Valid values are:
        \\
        \\  * `top` - Terminal appears at the top of the screen.
        \\  * `bottom` - Terminal appears at the bottom of the screen.
        \\  * `left` - Terminal appears at the left of the screen.
        \\  * `right` - Terminal appears at the right of the screen.
        \\  * `center` - Terminal appears at the center of the screen.
        \\
        \\On macOS, changing this configuration requires restarting Ghostty
        \\completely.
        \\
        \\Note: There is no default keybind for toggling the quick terminal.
        \\To enable this feature, bind the `toggle_quick_terminal` action to a key.
        ,
        .full_zh =
        \\“快速”终端窗口的位置。关于快速终端，详见 `toggle_quick_terminal` 绑定动作的文档。
        \\
        \\有效值：
        \\
        \\  * `top`：终端出现在屏幕顶部。
        \\  * `bottom`：终端出现在屏幕底部。
        \\  * `left`：终端出现在屏幕左侧。
        \\  * `right`：终端出现在屏幕右侧。
        \\  * `center`：终端出现在屏幕中央。
        \\
        \\在 macOS 上，改这项配置需要完全重启 Ghostty。
        \\
        \\注意：切换快速终端没有默认的快捷键。要使用这个功能，请把 `toggle_quick_terminal` 动作绑定到一个按键上。
        ,
    },
    .{
        .key = .@"quick-terminal-size",
        .en = "The size of the quick terminal.",
        .zh = "快速终端的大小。",
        .full_en =
        \\The size of the quick terminal.
        \\
        \\The size can be specified either as a percentage of the screen dimensions
        \\(height/width), or as an absolute size in pixels. Percentage values are
        \\suffixed with `%` (e.g. `20%`) while pixel values are suffixed with `px`
        \\(e.g. `300px`). A bare value without a suffix is a config error.
        \\
        \\When only one size is specified, the size parameter affects the size of
        \\the quick terminal on its *primary axis*, which depends on its position:
        \\height for quick terminals placed on the top or bottom, and width for left
        \\or right. The primary axis of a centered quick terminal depends on the
        \\monitor's orientation: height when on a landscape monitor, and width when
        \\on a portrait monitor.
        \\
        \\The *secondary axis* would be maximized for non-center positioned
        \\quick terminals unless another size parameter is specified, separated
        \\from the first by a comma (`,`). Percentage and pixel sizes can be mixed
        \\together: for instance, a size of `50%,500px` for a top-positioned quick
        \\terminal would be half a screen tall, and 500 pixels wide.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\快速终端的大小。
        \\
        \\大小可以写成屏幕尺寸（高/宽）的百分比，也可以写成以像素为单位的绝对大小。百分比带后缀 `%`（例如 `20%`），像素值带后缀 `px`（例如 `300px`）。不带后缀的数值是配置错误。
        \\
        \\只指定一个大小时，这个参数影响快速终端在其*主轴*上的大小，主轴取决于它的位置：放在顶部或底部的快速终端是高度，放在左侧或右侧的是宽度。居中的快速终端的主轴取决于显示器的方向：横屏显示器上是高度，竖屏显示器上是宽度。
        \\
        \\对于不居中的快速终端，*副轴*会撑满，除非再指定一个大小参数，用逗号（`,`）和第一个隔开。百分比和像素可以混用：例如，对于放在顶部的快速终端，大小 `50%,500px` 表示高度为半个屏幕，宽度为 500 像素。
        \\
        \\自 1.2.0 起可用。
        ,
    },
    .{
        .key = .@"gtk-quick-terminal-layer",
        .en = "The layer of the quick terminal window. The higher the layer, the more windows the quick terminal may conceal.",
        .zh = "快速终端窗口所在的层。层越高，快速终端能遮住的窗口越多。",
        .full_en =
        \\The layer of the quick terminal window. The higher the layer,
        \\the more windows the quick terminal may conceal.
        \\
        \\Valid values are:
        \\
        \\ * `overlay`
        \\
        \\   The quick terminal appears in front of all windows.
        \\
        \\ * `top` (default)
        \\
        \\   The quick terminal appears in front of normal windows but behind
        \\   fullscreen overlays like lock screens.
        \\
        \\ * `bottom`
        \\
        \\   The quick terminal appears behind normal windows but in front of
        \\   wallpapers and other windows in the background layer.
        \\
        \\ * `background`
        \\
        \\   The quick terminal appears behind all windows.
        \\
        \\GTK Wayland only.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\快速终端窗口所在的层。层越高，快速终端能遮住的窗口越多。
        \\
        \\有效值：
        \\
        \\ * `overlay`
        \\
        \\   快速终端出现在所有窗口前面。
        \\
        \\ * `top`（默认）
        \\
        \\   快速终端出现在普通窗口前面，但在锁屏等全屏覆盖层后面。
        \\
        \\ * `bottom`
        \\
        \\   快速终端出现在普通窗口后面，但在壁纸和背景层的其他窗口前面。
        \\
        \\ * `background`
        \\
        \\   快速终端出现在所有窗口后面。
        \\
        \\仅 GTK Wayland。
        \\
        \\自 1.2.0 起可用。
        ,
    },
    .{
        .key = .@"gtk-quick-terminal-namespace",
        .en = "The namespace for the quick terminal window.",
        .zh = "快速终端窗口的命名空间。",
        .full_en =
        \\The namespace for the quick terminal window.
        \\
        \\This is an identifier that is used by the Wayland compositor and/or
        \\scripts to determine the type of layer surfaces and to possibly apply
        \\unique effects.
        \\
        \\GTK Wayland only.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\快速终端窗口的命名空间。
        \\
        \\这是一个标识符，Wayland 合成器和/或脚本用它来判断层表面的类型，并可能据此应用特有的效果。
        \\
        \\仅 GTK Wayland。
        \\
        \\自 1.2.0 起可用。
        ,
    },
    .{
        .key = .@"quick-terminal-screen",
        .en = "The screen where the quick terminal should show up.",
        .zh = "快速终端应显示在哪块屏幕上。",
        .full_en =
        \\The screen where the quick terminal should show up.
        \\
        \\Valid values are:
        \\
        \\ * `main` - The screen that the operating system recommends as the main
        \\   screen. On macOS, this is the screen that is currently receiving
        \\   keyboard input. This screen is defined by the operating system and
        \\   not chosen by Ghostty.
        \\
        \\ * `mouse` - The screen that the mouse is currently hovered over.
        \\
        \\ * `macos-menu-bar` - The screen that contains the macOS menu bar as
        \\   set in the display settings on macOS. This is a bit confusing because
        \\   every screen on macOS has a menu bar, but this is the screen that
        \\   contains the primary menu bar.
        \\
        \\The default value is `main` because this is the recommended screen
        \\by the operating system.
        \\
        \\On macOS, `macos-menu-bar` uses the screen containing the menu bar.
        \\On Linux/Wayland, `macos-menu-bar` is treated as equivalent to `main`.
        \\
        \\Note: On Linux, there is no universal concept of a "primary" monitor.
        \\Ghostty uses the compositor-reported primary output when available and
        \\falls back to the first monitor reported by GDK if no primary output can
        \\be resolved.
        ,
        .full_zh =
        \\快速终端应显示在哪块屏幕上。
        \\
        \\有效值：
        \\
        \\ * `main`：操作系统推荐作为主屏幕的那块屏幕。在 macOS 上，就是当前接收键盘输入的屏幕。这块屏幕由操作系统决定，不是 Ghostty 选的。
        \\
        \\ * `mouse`：鼠标当前悬停所在的屏幕。
        \\
        \\ * `macos-menu-bar`：在 macOS 显示设置里设定的、带 macOS 菜单栏的那块屏幕。这有点让人困惑，因为 macOS 上每块屏幕都有菜单栏，但这指的是带主菜单栏的那块屏幕。
        \\
        \\默认值是 `main`，因为这是操作系统推荐的屏幕。
        \\
        \\在 macOS 上，`macos-menu-bar` 使用带菜单栏的那块屏幕。在 Linux/Wayland 上，`macos-menu-bar` 被视为等同于 `main`。
        \\
        \\注意：在 Linux 上，没有通用的“主”显示器的概念。Ghostty 在合成器报告了主输出时使用它；解析不出主输出时，退回 GDK 报告的第一个显示器。
        ,
    },
    .{
        .key = .@"quick-terminal-animation-duration",
        .en = "Duration (in seconds) of the quick terminal enter and exit animation. Set it to 0 to disable animation completely. This can be changed at runtime.",
        .zh = "快速终端进入和退出动画的时长（秒）。设为 0 可完全关闭动画。可在运行时修改。",
        .full_en =
        \\Duration (in seconds) of the quick terminal enter and exit animation.
        \\Set it to 0 to disable animation completely. This can be changed at
        \\runtime.
        \\
        \\Only implemented on macOS.
        ,
        .full_zh =
        \\快速终端进入和退出动画的时长（秒）。设为 0 可完全关闭动画。可在运行时修改。
        \\
        \\只在 macOS 上实现。
        ,
    },
    .{
        .key = .@"quick-terminal-autohide",
        .en = "Automatically hide the quick terminal when focus shifts to another window. Set it to false for the quick terminal to remain open even when it loses focus.",
        .zh = "焦点移到其他窗口时自动隐藏快速终端。设为 false 则快速终端即使失去焦点也保持打开。",
        .full_en =
        \\Automatically hide the quick terminal when focus shifts to another window.
        \\Set it to false for the quick terminal to remain open even when it loses focus.
        \\
        \\Defaults to true on macOS and on false on Linux/BSD. This is because global
        \\shortcuts on Linux require system configuration and are considerably less
        \\accessible than on macOS, meaning that it is more preferable to keep the
        \\quick terminal open until the user has completed their task.
        \\This default may change in the future.
        ,
        .full_zh =
        \\焦点移到其他窗口时自动隐藏快速终端。设为 false 则快速终端即使失去焦点也保持打开。
        \\
        \\在 macOS 上默认为 true，在 Linux/BSD 上默认为 false。这是因为 Linux 上的全局快捷键需要系统配置，远不如 macOS 上好用，所以更合适的做法是让快速终端一直开着，直到用户完成任务。这个默认值以后可能会改。
        ,
    },
    .{
        .key = .@"quick-terminal-space-behavior",
        .en = "This configuration option determines the behavior of the quick terminal when switching between macOS spaces. macOS spaces are virtual desktops that can be manually created or are automatically created when an application is in full-screen mode.",
        .zh = "这项配置决定在 macOS 的空间之间切换时，快速终端的行为。macOS 的空间是虚拟桌面，可以手动创建，应用进入全屏模式时也会自动创建。",
        .full_en =
        \\This configuration option determines the behavior of the quick terminal
        \\when switching between macOS spaces. macOS spaces are virtual desktops
        \\that can be manually created or are automatically created when an
        \\application is in full-screen mode.
        \\
        \\Valid values are:
        \\
        \\ * `move` - When switching to another space, the quick terminal will
        \\   also moved to the current space.
        \\
        \\ * `remain` - The quick terminal will stay only in the space where it
        \\   was originally opened and will not follow when switching to another
        \\   space.
        \\
        \\The default value is `move`.
        \\
        \\Only implemented on macOS.
        \\On Linux the behavior is always equivalent to `move`.
        \\
        \\Available since: 1.1.0
        ,
        .full_zh =
        \\这项配置决定在 macOS 的空间之间切换时，快速终端的行为。macOS 的空间是虚拟桌面，可以手动创建，应用进入全屏模式时也会自动创建。
        \\
        \\有效值：
        \\
        \\ * `move`：切换到另一个空间时，快速终端也跟着移到当前空间。
        \\
        \\ * `remain`：快速终端只留在它最初打开的那个空间，切换到另一个空间时不跟过去。
        \\
        \\默认值是 `move`。
        \\
        \\只在 macOS 上实现。在 Linux 上，行为总是等同于 `move`。
        \\
        \\自 1.1.0 起可用。
        ,
    },
    .{
        .key = .@"quick-terminal-keyboard-interactivity",
        .en = "Determines under which circumstances that the quick terminal should receive keyboard input. See the corresponding [Wayland documentation](https://wayland.app/protocols/wlr-layer-shell-unstable-v1#zwlr_layer_surface_v1:enum:keyboard_interactivity) for a more detailed explanation of the behavior of each option.",
        .zh = "决定在什么情况下快速终端应接收键盘输入。每个选项行为的详细说明，见对应的 [Wayland 文档](https://wayland.app/protocols/wlr-layer-shell-unstable-v1#zwlr_layer_surface_v1:enum:keyboard_interactivity)。",
        .full_en =
        \\Determines under which circumstances that the quick terminal should receive
        \\keyboard input. See the corresponding [Wayland documentation](https://wayland.app/protocols/wlr-layer-shell-unstable-v1#zwlr_layer_surface_v1:enum:keyboard_interactivity)
        \\for a more detailed explanation of the behavior of each option.
        \\
        \\> [!NOTE]
        \\> The exact behavior of each option may differ significantly across
        \\> compositors -- experiment with them on your system to find one that
        \\> suits your liking!
        \\
        \\Valid values are:
        \\
        \\ * `none`
        \\
        \\   The quick terminal will not receive any keyboard input.
        \\
        \\ * `on-demand` (default)
        \\
        \\   The quick terminal would only receive keyboard input when it is focused.
        \\
        \\ * `exclusive`
        \\
        \\   The quick terminal will always receive keyboard input, even when another
        \\   window is currently focused.
        \\
        \\Only has an effect on Linux Wayland.
        \\On macOS the behavior is always equivalent to `on-demand`.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\决定在什么情况下快速终端应接收键盘输入。每个选项行为的详细说明，见对应的 [Wayland 文档](https://wayland.app/protocols/wlr-layer-shell-unstable-v1#zwlr_layer_surface_v1:enum:keyboard_interactivity)。
        \\
        \\> [!NOTE]
        \\> 每个选项的具体行为在不同合成器之间可能差别很大，请在你的系统上试一试，找到一个合你心意的！
        \\
        \\有效值：
        \\
        \\ * `none`
        \\
        \\   快速终端不接收任何键盘输入。
        \\
        \\ * `on-demand`（默认）
        \\
        \\   快速终端只在获得焦点时接收键盘输入。
        \\
        \\ * `exclusive`
        \\
        \\   快速终端总是接收键盘输入，即使当前另一个窗口获得了焦点。
        \\
        \\只在 Linux Wayland 上有效。在 macOS 上，行为总是等同于 `on-demand`。
        \\
        \\自 1.2.0 起可用。
        ,
    },
    .{
        .key = .@"shell-integration",
        .en = "Whether to enable shell integration auto-injection or not. Shell integration greatly enhances the terminal experience by enabling a number of features:",
        .zh = "是否启用 shell 集成的自动注入。Shell 集成启用多项功能，能大大改善终端体验：",
        .full_en =
        \\Whether to enable shell integration auto-injection or not. Shell integration
        \\greatly enhances the terminal experience by enabling a number of features:
        \\
        \\  * Working directory reporting so new tabs, splits inherit the
        \\    previous terminal's working directory.
        \\
        \\  * Prompt marking that enables the "jump_to_prompt" keybinding.
        \\
        \\  * If you're sitting at a prompt, closing a terminal will not ask
        \\    for confirmation.
        \\
        \\  * Resizing the window with a complex prompt usually paints much
        \\    better.
        \\
        \\Allowable values are:
        \\
        \\  * `none` - Do not do any automatic injection. You can still manually
        \\    configure your shell to enable the integration.
        \\
        \\  * `detect` - Detect the shell based on the filename.
        \\
        \\  * `bash`, `elvish`, `fish`, `nushell`, `powershell`, `zsh` - Use this
        \\    specific shell injection scheme. `powershell` covers both
        \\    `powershell.exe` (Windows PowerShell 5.1) and `pwsh.exe`
        \\    (PowerShell 7+).
        \\
        \\The default value is `detect`.
        ,
        .full_zh =
        \\是否启用 shell 集成的自动注入。Shell 集成启用多项功能，能大大改善终端体验：
        \\
        \\  * 上报工作目录，让新标签页、新分屏继承上一个终端的工作目录。
        \\
        \\  * 标记提示符，启用 "jump_to_prompt" 快捷键。
        \\
        \\  * 如果你正停在提示符处，关闭终端时不会要求确认。
        \\
        \\  * 提示符比较复杂时，调整窗口大小通常绘制得好得多。
        \\
        \\可用的值：
        \\
        \\  * `none`：不做任何自动注入。你仍然可以手动配置你的 shell 来启用集成。
        \\
        \\  * `detect`：根据文件名检测 shell。
        \\
        \\  * `bash`、`elvish`、`fish`、`nushell`、`powershell`、`zsh`：使用这个特定 shell 的注入方式。`powershell` 同时涵盖 `powershell.exe`（Windows PowerShell 5.1）和 `pwsh.exe`（PowerShell 7+）。
        \\
        \\默认值是 `detect`。
        ,
    },
    .{
        .key = .@"shell-integration-features",
        .en = "Shell integration features to enable. These require our shell integration to be loaded, either automatically via shell-integration or manually.",
        .zh = "要启用的 shell 集成功能。这些功能需要先加载我们的 shell 集成，加载方式可以是通过 shell-integration 自动加载，也可以手动加载。",
        .full_en =
        \\Shell integration features to enable. These require our shell integration
        \\to be loaded, either automatically via shell-integration or manually.
        \\
        \\The format of this is a list of features to enable separated by commas. If
        \\you prefix a feature with `no-` then it is disabled. If you omit a feature,
        \\its default value is used, so you must explicitly disable features you don't
        \\want. You can also use `true` or `false` to turn all features on or off.
        \\
        \\Example: `cursor`, `no-cursor`, `sudo`, `no-sudo`, `title`, `no-title`
        \\
        \\Available features:
        \\
        \\  * `cursor` - Set the cursor to a bar at the prompt.
        \\
        \\  * `sudo` - Set sudo wrapper to preserve terminfo.
        \\
        \\  * `title` - Set the window title via shell integration.
        \\
        \\  * `ssh-env` - Enable SSH environment variable compatibility. Automatically
        \\    converts TERM from `xterm-ghostty` to `xterm-256color` when connecting to
        \\    remote hosts and propagates COLORTERM, TERM_PROGRAM, and TERM_PROGRAM_VERSION.
        \\    Whether or not these variables will be accepted by the remote host(s) will
        \\    depend on whether or not the variables are allowed in their sshd_config.
        \\    On by default in Polter (upstream Ghostty leaves it off); turn it off
        \\    with `shell-integration-features = no-ssh-env`.
        \\    (Available since: 1.2.0)
        \\
        \\  * `ssh-terminfo` - Enable automatic terminfo installation on remote hosts.
        \\    Attempts to install Ghostty's embedded terminfo entry using `tic` on local
        \\    cache misses. Requires `tic` to be available on remote hosts. Successful
        \\    installations are cached locally to avoid repeat installations.
        \\    If desired, the `+ssh-cache` CLI action can be used to manage the installation
        \\    cache manually using various arguments. On by default in Polter
        \\    (upstream Ghostty leaves it off); turn it off with
        \\    `shell-integration-features = no-ssh-terminfo`.
        \\    (Available since: 1.2.0)
        \\
        \\  * `path` - Add Ghostty's binary directory to PATH. This ensures the `ghostty`
        \\    command is available in the shell even if shell init scripts reset PATH.
        \\    This is particularly useful on macOS where PATH is often overridden by
        \\    system scripts. The directory is only added if not already present.
        \\
        \\  * `history` - Report each command about to run to Ghostty via a private
        \\    escape sequence, so a pane's command history can be saved and restored
        \\    as part of a saved project. On by default, because a project that
        \\    restores its panes' directories but not their commands is a
        \\    half-restored project, and the capture has to already have been
        \\    running by the time you save -- a feature you have to know to turn on
        \\    first is one that is off exactly when it would have been useful.
        \\    Unlike every other feature here, this writes what you type to disk
        \\    (one plain-text file per pane under Ghostty's state directory, mode
        \\    0600; see `src/CommandHistory.zig`). Turn it off with
        \\    `shell-integration-features = no-history`.
        \\
        \\SSH features work independently and can be combined for optimal experience:
        \\when both `ssh-env` and `ssh-terminfo` are enabled, Ghostty will install its
        \\terminfo on remote hosts and use `xterm-ghostty` as TERM, falling back to
        \\`xterm-256color` with environment variables if terminfo installation fails.
        ,
        .full_zh =
        \\要启用的 shell 集成功能。这些功能需要先加载我们的 shell 集成，加载方式可以是通过 shell-integration 自动加载，也可以手动加载。
        \\
        \\格式是用逗号分隔的、要启用的功能列表。功能前加 `no-` 表示禁用。省略的功能使用其默认值，所以不想要的功能必须明确禁用。也可以用 `true` 或 `false` 打开或关闭所有功能。
        \\
        \\示例：`cursor`、`no-cursor`、`sudo`、`no-sudo`、`title`、`no-title`
        \\
        \\可用的功能：
        \\
        \\  * `cursor`：在提示符处把光标设为竖线。
        \\
        \\  * `sudo`：设置 sudo 包装，以保留 terminfo。
        \\
        \\  * `title`：通过 shell 集成设置窗口标题。
        \\
        \\  * `ssh-env`：启用 SSH 环境变量兼容。连接远程主机时，自动把 TERM 从 `xterm-ghostty` 转换为 `xterm-256color`，并传递 COLORTERM、TERM_PROGRAM 和 TERM_PROGRAM_VERSION。远程主机是否接受这些变量，取决于它们的 sshd_config 是否允许这些变量。在 Polter 里默认开启（上游 Ghostty 默认关闭）；用 `shell-integration-features = no-ssh-env` 关闭。（自 1.2.0 起可用）
        \\
        \\  * `ssh-terminfo`：启用在远程主机上自动安装 terminfo。本地缓存未命中时，尝试用 `tic` 安装 Ghostty 内置的 terminfo 条目。要求远程主机上有 `tic`。安装成功的会缓存在本地，避免重复安装。需要的话，可以用 `+ssh-cache` 命令行动作配合各种参数手动管理安装缓存。在 Polter 里默认开启（上游 Ghostty 默认关闭）；用 `shell-integration-features = no-ssh-terminfo` 关闭。（自 1.2.0 起可用）
        \\
        \\  * `path`：把 Ghostty 程序所在目录加进 PATH。这确保即使 shell 初始化脚本重置了 PATH，shell 里也能用 `ghostty` 命令。在 PATH 常被系统脚本覆盖的 macOS 上尤其有用。只有目录还不在 PATH 里时才会添加。
        \\
        \\  * `history`：通过一个私有转义序列，把每条即将运行的命令报告给 Ghostty，这样窗格的命令历史可以作为已保存项目的一部分保存和恢复。默认开启，因为一个恢复了窗格目录却没恢复其命令的项目只恢复了一半，而且记录必须在你保存之前就已经在进行：一个你得先知道要打开的功能，恰恰在它本来有用的时候是关着的。和这里的其他所有功能不同，它会把你输入的内容写到磁盘上（每个窗格一个纯文本文件，放在 Ghostty 的状态目录下，权限 0600；见 `src/CommandHistory.zig`）。用 `shell-integration-features = no-history` 关闭。
        \\
        \\SSH 功能各自独立，可以组合使用以获得最佳体验：`ssh-env` 和 `ssh-terminfo` 都启用时，Ghostty 会在远程主机上安装它的 terminfo，并使用 `xterm-ghostty` 作为 TERM；如果 terminfo 安装失败，就退回 `xterm-256color` 加上环境变量。
        ,
    },
    .{
        .key = .@"command-palette-entry",
        .en = "Custom entries into the command palette.",
        .zh = "命令面板的自定义条目。",
        .full_en =
        \\Custom entries into the command palette.
        \\
        \\Each entry requires the title, the corresponding action, and an optional
        \\description. Each field should be prefixed with the field name, a colon
        \\(`:`), and then the specified value. The syntax for actions is identical
        \\to the one for keybind actions. Whitespace in between fields is ignored.
        \\
        \\If you need to embed commas or any other special characters in the values,
        \\enclose the value in double quotes and it will be interpreted as a Zig
        \\string literal. This is also useful for including whitespace at the
        \\beginning or the end of a value. See the
        \\[Zig documentation](https://ziglang.org/documentation/master/#Escape-Sequences)
        \\for more information on string literals. Note that multiline string literals
        \\are not supported.
        \\
        \\Double quotes can not be used around the field names.
        \\
        \\```ini
        \\command-palette-entry = title:Reset Font Style, action:csi:0m
        \\command-palette-entry = title:Crash on Main Thread,description:Causes a crash on the main (UI) thread.,action:crash:main
        \\command-palette-entry = title:Focus Split: Right,description:"Focus the split to the right, if it exists.",action:goto_split:right
        \\command-palette-entry = title:"Ghostty",description:"Add a little Ghostty to your terminal.",action:"text:\xf0\x9f\x91\xbb"
        \\```
        \\
        \\There are some additional special values that can be specified for
        \\command-palette-entry:
        \\
        \\  * `command-palette-entry=clear` will clear all command entries. Warning: this
        \\    removes ALL entries up to this point, including the default
        \\    entries. Available since: 1.4.0
        \\
        \\By default, the command palette is preloaded with most actions that might
        \\be useful in an interactive setting yet do not have easily accessible or
        \\memorizable shortcuts. The default entries can be restored by setting this
        \\setting to an empty value:
        \\
        \\```ini
        \\command-palette-entry =
        \\```
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\命令面板的自定义条目。
        \\
        \\每个条目需要标题、对应的动作，以及一个可选的描述。每个字段都要以字段名加冒号（`:`）开头，后面跟指定的值。动作的语法和按键绑定的动作完全相同。字段之间的空白会被忽略。
        \\
        \\如果需要在值里嵌入逗号或其他特殊字符，就用双引号把值包起来，它会被当作 Zig 字符串字面量解释。这也可以用来在值的开头或结尾包含空白。关于字符串字面量的更多信息，见 [Zig 文档](https://ziglang.org/documentation/master/#Escape-Sequences)。注意不支持多行字符串字面量。
        \\
        \\字段名两边不能用双引号。
        \\
        \\```ini
        \\command-palette-entry = title:Reset Font Style, action:csi:0m
        \\command-palette-entry = title:Crash on Main Thread,description:Causes a crash on the main (UI) thread.,action:crash:main
        \\command-palette-entry = title:Focus Split: Right,description:"Focus the split to the right, if it exists.",action:goto_split:right
        \\command-palette-entry = title:"Ghostty",description:"Add a little Ghostty to your terminal.",action:"text:\xf0\x9f\x91\xbb"
        \\```
        \\
        \\command-palette-entry 还可以指定一些额外的特殊值：
        \\
        \\  * `command-palette-entry=clear` 会清除所有命令条目。警告：这会删除到此为止的**所有**条目，包括默认条目。自 1.4.0 起可用
        \\
        \\默认情况下，命令面板预先载入了大部分在交互场景下可能有用、却没有容易找到或容易记住的快捷键的动作。把这项设置设为空值，可以恢复默认条目：
        \\
        \\```ini
        \\command-palette-entry =
        \\```
        \\
        \\自 1.2.0 起可用。
        ,
    },
    .{
        .key = .@"osc-color-report-format",
        .en = "Sets the reporting format for OSC sequences that request color information. Ghostty currently supports OSC 10 (foreground), OSC 11 (background), and OSC 4 (256 color palette) queries, and by default the reported values are scaled-up RGB values, where each component are 16 bits. This is how most terminals report these values. However, some legacy applications may require 8-bit, unscaled, components. We also support turning off reporting altogether. The components are lowercase hex values.",
        .zh = "设置请求颜色信息的 OSC 序列的上报格式。Ghostty 目前支持 OSC 10（前景色）、OSC 11（背景色）和 OSC 4（256 色调色板）查询，默认上报放大后的 RGB 值，每个分量 16 位。大多数终端都是这样上报这些值的。不过，一些老旧程序可能需要 8 位、未放大的分量。我们也支持完全关闭上报。分量为小写十六进制值。",
        .full_en =
        \\Sets the reporting format for OSC sequences that request color information.
        \\Ghostty currently supports OSC 10 (foreground), OSC 11 (background), and
        \\OSC 4 (256 color palette) queries, and by default the reported values
        \\are scaled-up RGB values, where each component are 16 bits. This is how
        \\most terminals report these values. However, some legacy applications may
        \\require 8-bit, unscaled, components. We also support turning off reporting
        \\altogether. The components are lowercase hex values.
        \\
        \\Allowable values are:
        \\
        \\  * `none` - OSC 4/10/11 queries receive no reply
        \\
        \\  * `8-bit` - Color components are return unscaled, e.g. `rr/gg/bb`
        \\
        \\  * `16-bit` - Color components are returned scaled, e.g. `rrrr/gggg/bbbb`
        \\
        \\The default value is `16-bit`.
        ,
        .full_zh =
        \\设置请求颜色信息的 OSC 序列的上报格式。Ghostty 目前支持 OSC 10（前景色）、OSC 11（背景色）和 OSC 4（256 色调色板）查询，默认上报放大后的 RGB 值，每个分量 16 位。大多数终端都是这样上报这些值的。不过，一些老旧程序可能需要 8 位、未放大的分量。我们也支持完全关闭上报。分量为小写十六进制值。
        \\
        \\可用的值：
        \\
        \\  * `none`：OSC 4/10/11 查询不回复
        \\
        \\  * `8-bit`：颜色分量不放大，例如 `rr/gg/bb`
        \\
        \\  * `16-bit`：颜色分量放大，例如 `rrrr/gggg/bbbb`
        \\
        \\默认值是 `16-bit`。
        ,
    },
    .{ .key = .@"vt-kam-allowed", .en = "If true, allows the \"KAM\" mode (ANSI mode 2) to be used within the terminal. KAM disables keyboard input at the request of the application. This is not a common feature and is not recommended to be enabled. This will not be documented further because if you know you need KAM, you know. If you don't know if you need KAM, you don't need it.", .zh = "设为 true 时，允许在终端里使用 “KAM” 模式（ANSI 模式 2）。KAM 会应程序要求禁用键盘输入。这不是常见功能，不建议启用。这里不再多作说明：如果你知道自己需要 KAM，你就知道；如果你不知道自己是否需要 KAM，那就不需要。" },
    .{
        .key = .@"custom-shader",
        .en = "Custom shaders to run after the default shaders. This is a file path to a GLSL-syntax shader for all platforms.",
        .zh = "在默认着色器之后运行的自定义着色器。这是一个 GLSL 语法着色器的文件路径，所有平台通用。",
        .full_en =
        \\Custom shaders to run after the default shaders. This is a file path
        \\to a GLSL-syntax shader for all platforms.
        \\
        \\Warning: Invalid shaders can cause Ghostty to become unusable such as by
        \\causing the window to be completely black. If this happens, you can
        \\unset this configuration to disable the shader.
        \\
        \\Custom shader support is based on and compatible with the Shadertoy shaders.
        \\Shaders should specify a `mainImage` function and the available uniforms
        \\largely match Shadertoy, with some caveats and Ghostty-specific extensions.
        \\
        \\The uniform values available to shaders are as follows:
        \\
        \\ * `sampler2D iChannel0` - Input texture.
        \\
        \\   A texture containing the current terminal screen. If multiple custom
        \\   shaders are specified, the output of previous shaders is written to
        \\   this texture, to allow combining multiple effects.
        \\
        \\ * `vec3 iResolution` - Output texture size, `[width, height, 1]` (in px).
        \\
        \\ * `float iTime` - Time in seconds since first frame was rendered.
        \\
        \\ * `float iTimeDelta` - Time in seconds since previous frame was rendered.
        \\
        \\ * `float iFrameRate` - Average framerate. (NOT CURRENTLY SUPPORTED)
        \\
        \\ * `int iFrame` - Number of frames that have been rendered so far.
        \\
        \\ * `float iChannelTime[4]` - Current time for video or sound input. (N/A)
        \\
        \\ * `vec3 iChannelResolution[4]` - Resolutions of the 4 input samplers.
        \\
        \\   Currently only `iChannel0` exists, and `iChannelResolution[0]` is
        \\   identical to `iResolution`.
        \\
        \\ * `vec4 iMouse` - Mouse input info. (NOT CURRENTLY SUPPORTED)
        \\
        \\ * `vec4 iDate` - Date/time info. (NOT CURRENTLY SUPPORTED)
        \\
        \\ * `float iSampleRate` - Sample rate for audio. (N/A)
        \\
        \\Ghostty-specific extensions:
        \\
        \\ * `vec4 iCurrentCursor` - Info about the terminal cursor.
        \\
        \\   - `iCurrentCursor.xy` is the -X, +Y corner of the current cursor.
        \\   - `iCurrentCursor.zw` is the width and height of the current cursor.
        \\
        \\ * `vec4 iPreviousCursor` - Info about the previous terminal cursor.
        \\
        \\ * `vec4 iCurrentCursorColor` - Color of the terminal cursor.
        \\
        \\ * `vec4 iPreviousCursorColor` - Color of the previous terminal cursor.
        \\
        \\ * `vec4 iCurrentCursorStyle` - Style of the terminal cursor
        \\
        \\   Macros simplified use are defined for the various cursor styles:
        \\
        \\   - `CURSORSTYLE_BLOCK` or `0`
        \\   - `CURSORSTYLE_BLOCK_HOLLOW` or `1`
        \\   - `CURSORSTYLE_BAR` or `2`
        \\   - `CURSORSTYLE_UNDERLINE` or `3`
        \\   - `CURSORSTYLE_LOCK` or `4`
        \\
        \\ * `vec4 iPreviousCursorStyle` - Style of the previous terminal cursor
        \\
        \\ * `vec4 iCursorVisible` - Visibility of the terminal cursor.
        \\
        \\ * `float iTimeCursorChange` - Timestamp of terminal cursor change.
        \\
        \\   When the terminal cursor changes position or color, this is set to
        \\   the same time as the `iTime` uniform, allowing you to compute the
        \\   time since the change by subtracting this from `iTime`.
        \\
        \\ * `float iTimeFocus` - Timestamp when the surface last gained iFocus.
        \\
        \\   When the surface gains focus, this is set to the current value of
        \\   `iTime`, similar to how `iTimeCursorChange` works. This allows you
        \\   to compute the time since focus was gained or lost by calculating
        \\   `iTime - iTimeFocus`. Use this to create animations that restart
        \\   when the terminal regains focus.
        \\
        \\ * `int iFocus` - Current focus state of the surface.
        \\
        \\   Set to 1.0 when the surface is focused, 0.0 when unfocused. This
        \\   allows shaders to detect unfocused state and avoid animation artifacts
        \\   from large time deltas caused by infrequent "deceptive frames"
        \\   (e.g., modifier key presses, link hover events in unfocused split panes).
        \\   Check `iFocus > 0` to determine if the surface is currently focused.
        \\
        \\ * `vec3 iPalette[256]` - The 256-color terminal palette.
        \\
        \\   RGB values for all 256 colors in the terminal palette, normalized
        \\   to [0.0, 1.0]. Index 0-15 are the ANSI colors, 16-231 are the 6x6x6
        \\   color cube, and 232-255 are the grayscale colors.
        \\
        \\ * `vec3 iBackgroundColor` - Terminal background color (RGB).
        \\
        \\ * `vec3 iForegroundColor` - Terminal foreground color (RGB).
        \\
        \\ * `vec3 iCursorColor` - Terminal cursor color (RGB).
        \\
        \\ * `vec3 iCursorText` - Terminal cursor text color (RGB).
        \\
        \\ * `vec3 iSelectionBackgroundColor` - Selection background color (RGB).
        \\
        \\ * `vec3 iSelectionForegroundColor` - Selection foreground color (RGB).
        \\
        \\If the shader fails to compile, the shader will be ignored. Any errors
        \\related to shader compilation will not show up as configuration errors
        \\and only show up in the log, since shader compilation happens after
        \\configuration loading on the dedicated render thread.  For interactive
        \\development, use [shadertoy.com](https://shadertoy.com).
        \\
        \\This can be repeated multiple times to load multiple shaders. The shaders
        \\will be run in the order they are specified.
        \\
        \\This can be changed at runtime and will affect all open terminals.
        ,
        .full_zh =
        \\在默认着色器之后运行的自定义着色器。这是一个 GLSL 语法着色器的文件路径，所有平台通用。
        \\
        \\警告：无效的着色器可能让 Ghostty 无法使用，比如让窗口变成全黑。如果发生这种情况，取消设置这项配置即可停用着色器。
        \\
        \\自定义着色器的支持基于 Shadertoy 着色器，并与之兼容。着色器应该提供一个 `mainImage` 函数，可用的 uniform 基本和 Shadertoy 一致，有一些例外，还有一些 Ghostty 特有的扩展。
        \\
        \\着色器可用的 uniform 值如下：
        \\
        \\ * `sampler2D iChannel0`：输入纹理。
        \\
        \\   包含当前终端屏幕的纹理。如果指定了多个自定义着色器，前面着色器的输出会写进这个纹理，以便组合多种效果。
        \\
        \\ * `vec3 iResolution`：输出纹理的大小，`[width, height, 1]`（单位 px）。
        \\
        \\ * `float iTime`：自第一帧渲染以来经过的秒数。
        \\
        \\ * `float iTimeDelta`：自上一帧渲染以来经过的秒数。
        \\
        \\ * `float iFrameRate`：平均帧率。（目前不支持）
        \\
        \\ * `int iFrame`：到目前为止已渲染的帧数。
        \\
        \\ * `float iChannelTime[4]`：视频或声音输入的当前时间。（不适用）
        \\
        \\ * `vec3 iChannelResolution[4]`：4 个输入采样器的分辨率。
        \\
        \\   目前只有 `iChannel0`，`iChannelResolution[0]` 和 `iResolution` 相同。
        \\
        \\ * `vec4 iMouse`：鼠标输入信息。（目前不支持）
        \\
        \\ * `vec4 iDate`：日期/时间信息。（目前不支持）
        \\
        \\ * `float iSampleRate`：音频采样率。（不适用）
        \\
        \\Ghostty 特有的扩展：
        \\
        \\ * `vec4 iCurrentCursor`：终端光标的信息。
        \\
        \\   - `iCurrentCursor.xy` 是当前光标的 -X、+Y 角。
        \\   - `iCurrentCursor.zw` 是当前光标的宽度和高度。
        \\
        \\ * `vec4 iPreviousCursor`：上一个终端光标的信息。
        \\
        \\ * `vec4 iCurrentCursorColor`：终端光标的颜色。
        \\
        \\ * `vec4 iPreviousCursorColor`：上一个终端光标的颜色。
        \\
        \\ * `vec4 iCurrentCursorStyle`：终端光标的样式
        \\
        \\   为各种光标样式定义了简化使用的宏：
        \\
        \\   - `CURSORSTYLE_BLOCK` 或 `0`
        \\   - `CURSORSTYLE_BLOCK_HOLLOW` 或 `1`
        \\   - `CURSORSTYLE_BAR` 或 `2`
        \\   - `CURSORSTYLE_UNDERLINE` 或 `3`
        \\   - `CURSORSTYLE_LOCK` 或 `4`
        \\
        \\ * `vec4 iPreviousCursorStyle`：上一个终端光标的样式
        \\
        \\ * `vec4 iCursorVisible`：终端光标是否可见。
        \\
        \\ * `float iTimeCursorChange`：终端光标变化的时间戳。
        \\
        \\   终端光标改变位置或颜色时，它被设为和 `iTime` uniform 相同的时间，这样用 `iTime` 减去它，就能算出自变化以来过了多久。
        \\
        \\ * `float iTimeFocus`：终端最近一次获得 iFocus 的时间戳。
        \\
        \\   终端获得焦点时，它被设为 `iTime` 的当前值，和 `iTimeCursorChange` 的做法类似。这样可以通过计算 `iTime - iTimeFocus` 得出自获得或失去焦点以来过了多久。可以用它做出终端重新获得焦点时重新开始的动画。
        \\
        \\ * `int iFocus`：终端当前的焦点状态。
        \\
        \\   终端获得焦点时设为 1.0，失去焦点时设为 0.0。这让着色器能检测到失去焦点的状态，避免因不频繁的“欺骗性帧”（例如修饰键按下、未获得焦点的分屏窗格里的链接悬停事件）造成的巨大时间差而产生动画瑕疵。用 `iFocus > 0` 判断终端当前是否获得焦点。
        \\
        \\ * `vec3 iPalette[256]`：256 色终端调色板。
        \\
        \\   终端调色板里全部 256 种颜色的 RGB 值，归一化到 [0.0, 1.0]。索引 0-15 是 ANSI 颜色，16-231 是 6x6x6 色立方，232-255 是灰阶颜色。
        \\
        \\ * `vec3 iBackgroundColor`：终端背景色（RGB）。
        \\
        \\ * `vec3 iForegroundColor`：终端前景色（RGB）。
        \\
        \\ * `vec3 iCursorColor`：终端光标颜色（RGB）。
        \\
        \\ * `vec3 iCursorText`：终端光标文字颜色（RGB）。
        \\
        \\ * `vec3 iSelectionBackgroundColor`：选区背景色（RGB）。
        \\
        \\ * `vec3 iSelectionForegroundColor`：选区前景色（RGB）。
        \\
        \\如果着色器编译失败，着色器会被忽略。与着色器编译相关的错误不会显示为配置错误，只会出现在日志里，因为着色器编译发生在配置加载之后、专门的渲染线程上。交互式开发请用 [shadertoy.com](https://shadertoy.com)。
        \\
        \\可以重复多次，加载多个着色器。着色器按指定的顺序运行。
        \\
        \\可以在运行时修改，会影响所有打开的终端。
        ,
    },
    .{
        .key = .@"custom-shader-animation",
        .en = "If `true` (default), the focused terminal surface will run an animation loop when custom shaders are used. This uses slightly more CPU (generally less than 10%) but allows the shader to animate. This only runs if there are custom shaders and the terminal is focused.",
        .zh = "为 `true`（默认）时，使用自定义着色器的情况下，获得焦点的终端会运行动画循环。这会稍多占用一点 CPU（通常不到 10%），但让着色器能够产生动画。只有存在自定义着色器且终端获得焦点时才会运行。",
        .full_en =
        \\If `true` (default), the focused terminal surface will run an animation
        \\loop when custom shaders are used. This uses slightly more CPU (generally
        \\less than 10%) but allows the shader to animate. This only runs if there
        \\are custom shaders and the terminal is focused.
        \\
        \\If this is set to `false`, the terminal and custom shader will only render
        \\when the terminal is updated. This is more efficient but the shader will
        \\not animate.
        \\
        \\This can also be set to `always`, which will always run the animation
        \\loop regardless of whether the terminal is focused or not. The animation
        \\loop will still only run when custom shaders are used. Note that this
        \\will use more CPU per terminal surface and can become quite expensive
        \\depending on the shader and your terminal usage.
        \\
        \\This can be changed at runtime and will affect all open terminals.
        ,
        .full_zh =
        \\为 `true`（默认）时，使用自定义着色器的情况下，获得焦点的终端会运行动画循环。这会稍多占用一点 CPU（通常不到 10%），但让着色器能够产生动画。只有存在自定义着色器且终端获得焦点时才会运行。
        \\
        \\设为 `false` 时，终端和自定义着色器只在终端内容更新时才渲染。这样效率更高，但着色器不会动。
        \\
        \\也可以设为 `always`，不管终端有没有焦点，总是运行动画循环。动画循环仍然只在使用自定义着色器时运行。注意这会让每个终端占用更多 CPU，视着色器和你使用终端的方式而定，开销可能相当大。
        \\
        \\可以在运行时修改，会影响所有打开的终端。
        ,
    },
    .{
        .key = .@"bell-features",
        .en = "Bell features to enable if bell support is available in your runtime. Not all features are available on all runtimes. The format of this is a list of features to enable separated by commas. If you prefix a feature with `no-` then it is disabled. If you omit a feature, its default value is used.",
        .zh = "在你的运行环境支持响铃时，要启用的响铃功能。并非所有运行环境都提供所有功能。格式是用逗号分隔的、要启用的功能列表。功能前加 `no-` 表示禁用。省略的功能使用其默认值。",
        .full_en =
        \\Bell features to enable if bell support is available in your runtime. Not
        \\all features are available on all runtimes. The format of this is a list of
        \\features to enable separated by commas. If you prefix a feature with `no-`
        \\then it is disabled. If you omit a feature, its default value is used.
        \\
        \\Valid values are:
        \\
        \\ * `system`
        \\
        \\   Instruct the system to notify the user using built-in system functions.
        \\   This could result in an audiovisual effect, a notification, or something
        \\   else entirely. Changing these effects require altering system settings:
        \\   for instance under the "Sound > Alert Sound" setting in GNOME,
        \\   or the "Accessibility > System Bell" settings in KDE Plasma.
        \\
        \\   On macOS, this plays the system alert sound.
        \\
        \\ * `audio`
        \\
        \\   Play a custom sound. (Available since 1.3.0 on macOS)
        \\
        \\ * `attention` *(enabled by default)*
        \\
        \\   Request the user's attention when Ghostty is unfocused, until it has
        \\   received focus again. On macOS, this will bounce the app icon in the
        \\   dock once. On Linux, the behavior depends on the desktop environment
        \\   and/or the window manager/compositor:
        \\
        \\   - On KDE, the background of the desktop icon in the task bar would be
        \\     highlighted;
        \\
        \\   - On GNOME, you may receive a notification that, when clicked, would
        \\     bring the Ghostty window into focus;
        \\
        \\   - On Sway, the window may be decorated with a distinctly colored border;
        \\
        \\   - On other systems this may have no effect at all.
        \\
        \\ * `title` *(enabled by default)*
        \\
        \\   Prepend a bell emoji (🔔) to the title of the alerted surface until the
        \\   terminal is re-focused or interacted with (such as on keyboard input).
        \\
        \\ * `border`
        \\
        \\   Display a border around the alerted surface until the terminal is
        \\   re-focused or interacted with (such as on keyboard input).
        \\
        \\   Available since: 1.2.0 on GTK, 1.2.1 on macOS
        \\
        \\Example: `audio`, `no-audio`, `system`, `no-system`
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\在你的运行环境支持响铃时，要启用的响铃功能。并非所有运行环境都提供所有功能。格式是用逗号分隔的、要启用的功能列表。功能前加 `no-` 表示禁用。省略的功能使用其默认值。
        \\
        \\有效值：
        \\
        \\ * `system`
        \\
        \\   让系统用内置的系统功能通知用户。结果可能是一个声光效果、一条通知，或者完全是别的东西。要改变这些效果，需要修改系统设置：例如 GNOME 里的“声音 > 提示音”设置，或 KDE Plasma 里的“辅助功能 > 系统响铃”设置。
        \\
        \\   在 macOS 上，这会播放系统提示音。
        \\
        \\ * `audio`
        \\
        \\   播放一段自定义声音。（在 macOS 上自 1.3.0 起可用）
        \\
        \\ * `attention` *（默认启用）*
        \\
        \\   Ghostty 没有焦点时请求用户注意，直到它重新获得焦点。在 macOS 上，这会让程序坞里的应用图标跳动一次。在 Linux 上，行为取决于桌面环境和/或窗口管理器/合成器：
        \\
        \\   - 在 KDE 上，任务栏里桌面图标的背景会被高亮；
        \\
        \\   - 在 GNOME 上，你可能会收到一条通知，点击后会让 Ghostty 窗口获得焦点；
        \\
        \\   - 在 Sway 上，窗口可能会被加上一圈颜色醒目的边框；
        \\
        \\   - 在其他系统上，这可能完全不起作用。
        \\
        \\ * `title` *（默认启用）*
        \\
        \\   在发出提醒的终端标题前加一个铃铛表情（🔔），直到终端重新获得焦点或被操作（例如键盘输入）。
        \\
        \\ * `border`
        \\
        \\   在发出提醒的终端周围显示一圈边框，直到终端重新获得焦点或被操作（例如键盘输入）。
        \\
        \\   自 GTK 1.2.0、macOS 1.2.1 起可用
        \\
        \\示例：`audio`、`no-audio`、`system`、`no-system`
        \\
        \\自 1.2.0 起可用
        ,
    },
    .{
        .key = .@"bell-audio-path",
        .en = "If `audio` is an enabled bell feature, this is a path to an audio file. If the path is not absolute, it is considered relative to the directory of the configuration file that it is referenced from, or from the current working directory if this is used as a CLI flag. The path may be prefixed with `~/` to reference the user's home directory.",
        .zh = "如果 `audio` 是已启用的响铃功能，这里是音频文件的路径。路径不是绝对路径时，相对于引用它的配置文件所在目录；若是作为命令行参数使用，则相对于当前工作目录。路径可以用 `~/` 开头表示用户主目录。",
        .full_en =
        \\If `audio` is an enabled bell feature, this is a path to an audio file. If
        \\the path is not absolute, it is considered relative to the directory of the
        \\configuration file that it is referenced from, or from the current working
        \\directory if this is used as a CLI flag. The path may be prefixed with `~/`
        \\to reference the user's home directory.
        \\
        \\Available since: 1.2.0 on GTK, 1.3.0 on macOS.
        ,
        .full_zh =
        \\如果 `audio` 是已启用的响铃功能，这里是音频文件的路径。路径不是绝对路径时，相对于引用它的配置文件所在目录；若是作为命令行参数使用，则相对于当前工作目录。路径可以用 `~/` 开头表示用户主目录。
        \\
        \\自 GTK 1.2.0、macOS 1.3.0 起可用。
        ,
    },
    .{
        .key = .@"bell-audio-volume",
        .en = "If `audio` is an enabled bell feature, this is the volume to play the audio file at (relative to the system volume). This is a floating point number ranging from 0.0 (silence) to 1.0 (as loud as possible). The default is 0.5.",
        .zh = "如果 `audio` 是已启用的响铃功能，这里是播放音频文件的音量（相对于系统音量）。这是一个浮点数，范围从 0.0（静音）到 1.0（最大声）。默认为 0.5。",
        .full_en =
        \\If `audio` is an enabled bell feature, this is the volume to play the audio
        \\file at (relative to the system volume). This is a floating point number
        \\ranging from 0.0 (silence) to 1.0 (as loud as possible). The default is 0.5.
        \\
        \\Available since: 1.2.0 on GTK, 1.3.0 on macOS.
        ,
        .full_zh =
        \\如果 `audio` 是已启用的响铃功能，这里是播放音频文件的音量（相对于系统音量）。这是一个浮点数，范围从 0.0（静音）到 1.0（最大声）。默认为 0.5。
        \\
        \\自 GTK 1.2.0、macOS 1.3.0 起可用。
        ,
    },
    .{
        .key = .@"app-notifications",
        .en = "Control the in-app notifications that Ghostty shows.",
        .zh = "控制 Ghostty 显示的应用内通知。",
        .full_en =
        \\Control the in-app notifications that Ghostty shows.
        \\
        \\On Linux (GTK), in-app notifications show up as toasts. Toasts appear
        \\overlaid on top of the terminal window. They are used to show information
        \\that is not critical but may be important.
        \\
        \\Possible notifications are:
        \\
        \\  - `clipboard-copy` (default: true) - Show a notification when text is copied
        \\    to the clipboard.
        \\  - `config-reload` (default: true) - Show a notification when
        \\    the configuration is reloaded.
        \\
        \\To specify a notification to enable, specify the name of the notification.
        \\To specify a notification to disable, prefix the name with `no-`. For
        \\example, to disable `clipboard-copy`, set this configuration to
        \\`no-clipboard-copy`. To enable it, set this configuration to `clipboard-copy`.
        \\
        \\Multiple notifications can be enabled or disabled by separating them
        \\with a comma.
        \\
        \\A value of "false" will disable all notifications. A value of "true" will
        \\enable all notifications.
        \\
        \\This configuration only applies to GTK.
        \\
        \\Available since: 1.1.0
        ,
        .full_zh =
        \\控制 Ghostty 显示的应用内通知。
        \\
        \\在 Linux（GTK）上，应用内通知以浮动提示的形式出现。浮动提示叠加显示在终端窗口上方，用来显示不关键、但可能重要的信息。
        \\
        \\可能的通知有：
        \\
        \\  - `clipboard-copy`（默认：true）：文本复制到剪贴板时显示通知。
        \\  - `config-reload`（默认：true）：配置重新加载时显示通知。
        \\
        \\要启用某个通知，写上它的名字。要禁用某个通知，在名字前加 `no-`。例如，要禁用 `clipboard-copy`，就把这项配置设为 `no-clipboard-copy`；要启用它，就设为 `clipboard-copy`。
        \\
        \\可以用逗号隔开，同时启用或禁用多个通知。
        \\
        \\值 "false" 禁用所有通知。值 "true" 启用所有通知。
        \\
        \\这项配置只适用于 GTK。
        \\
        \\自 1.1.0 起可用
        ,
    },
    .{
        .key = .@"macos-non-native-fullscreen",
        .en = "If anything other than false, fullscreen mode on macOS will not use the native fullscreen, but make the window fullscreen without animations and using a new space. It's faster than the native fullscreen mode since it doesn't use animations.",
        .zh = "不是 false 时，macOS 上的全屏模式不使用原生全屏，而是不带动画、使用新空间让窗口全屏。因为没有动画，它比原生全屏模式更快。",
        .full_en =
        \\If anything other than false, fullscreen mode on macOS will not use the
        \\native fullscreen, but make the window fullscreen without animations and
        \\using a new space. It's faster than the native fullscreen mode since it
        \\doesn't use animations.
        \\
        \\Important: tabs DO NOT WORK in this mode. Non-native fullscreen removes
        \\the titlebar and macOS native tabs require the titlebar. If you use tabs,
        \\you should not use this mode.
        \\
        \\If you fullscreen a window with tabs, the currently focused tab will
        \\become fullscreen while the others will remain in a separate window in
        \\the background. You can switch to that window using normal window-switching
        \\keybindings such as command+tilde. When you exit fullscreen, the window
        \\will return to the tabbed state it was in before.
        \\
        \\Allowable values are:
        \\
        \\  * `true` - Use non-native macOS fullscreen, hide the menu bar
        \\  * `false` - Use native macOS fullscreen
        \\  * `visible-menu` - Use non-native macOS fullscreen, keep the menu bar
        \\    visible
        \\  * `padded-notch` - Use non-native macOS fullscreen, hide the menu bar,
        \\    but ensure the window is not obscured by the notch on applicable
        \\    devices. The area around the notch will remain transparent currently,
        \\    but in the future we may fill it with the window background color.
        \\
        \\Changing this option at runtime works, but will only apply to the next
        \\time the window is made fullscreen. If a window is already fullscreen,
        \\it will retain the previous setting until fullscreen is exited.
        ,
        .full_zh =
        \\不是 false 时，macOS 上的全屏模式不使用原生全屏，而是不带动画、使用新空间让窗口全屏。因为没有动画，它比原生全屏模式更快。
        \\
        \\重要：标签页在这个模式下完全不能用。非原生全屏会去掉标题栏，而 macOS 原生标签页需要标题栏。如果你使用标签页，就不应该用这个模式。
        \\
        \\如果你把一个带标签页的窗口全屏，当前获得焦点的标签页会变成全屏，其他标签页则留在后台一个单独的窗口里。你可以用 command+波浪号之类的常规窗口切换快捷键切换到那个窗口。退出全屏时，窗口会回到之前带标签页的状态。
        \\
        \\可用的值：
        \\
        \\  * `true`：使用非原生 macOS 全屏，隐藏菜单栏
        \\  * `false`：使用原生 macOS 全屏
        \\  * `visible-menu`：使用非原生 macOS 全屏，保留菜单栏可见
        \\  * `padded-notch`：使用非原生 macOS 全屏，隐藏菜单栏，但在有刘海的设备上确保窗口不被刘海挡住。刘海周围的区域目前会保持透明，以后我们可能会用窗口背景色填充它。
        \\
        \\在运行时修改这个选项可以，但只在下一次让窗口全屏时生效。如果窗口已经是全屏，它会保持之前的设置，直到退出全屏。
        ,
    },
    .{
        .key = .@"macos-window-buttons",
        .en = "Whether the window buttons in the macOS titlebar are visible. The window buttons are the colored buttons in the upper left corner of most macOS apps, also known as the traffic lights, that allow you to close, miniaturize, and zoom the window.",
        .zh = "macOS 标题栏里的窗口按钮是否可见。窗口按钮是大多数 macOS 应用左上角的彩色按钮，也叫红绿灯，可用来关闭、最小化和缩放窗口。",
        .full_en =
        \\Whether the window buttons in the macOS titlebar are visible. The window
        \\buttons are the colored buttons in the upper left corner of most macOS apps,
        \\also known as the traffic lights, that allow you to close, miniaturize, and
        \\zoom the window.
        \\
        \\This setting has no effect when `window-decoration = none` or
        \\`macos-titlebar-style = hidden`, as the window buttons are always hidden in
        \\these modes.
        \\
        \\Valid values are:
        \\
        \\  * `visible` - Show the window buttons.
        \\  * `hidden` - Hide the window buttons.
        \\
        \\The default value is `visible`.
        \\
        \\Changing this option at runtime only applies to new windows.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\macOS 标题栏里的窗口按钮是否可见。窗口按钮是大多数 macOS 应用左上角的彩色按钮，也叫红绿灯，可用来关闭、最小化和缩放窗口。
        \\
        \\`window-decoration = none` 或 `macos-titlebar-style = hidden` 时，这项设置不起作用，因为这些模式下窗口按钮总是隐藏的。
        \\
        \\有效值：
        \\
        \\  * `visible`：显示窗口按钮。
        \\  * `hidden`：隐藏窗口按钮。
        \\
        \\默认值是 `visible`。
        \\
        \\在运行时修改这个选项，只适用于新窗口。
        \\
        \\自 1.2.0 起可用
        ,
    },
    .{
        .key = .@"macos-titlebar-style",
        .en = "The style of the macOS titlebar. Available values are: \"native\", \"transparent\", \"tabs\", and \"hidden\".",
        .zh = "macOS 标题栏的样式。可用值为：\"native\"、\"transparent\"、\"tabs\" 和 \"hidden\"。",
        .full_en =
        \\The style of the macOS titlebar. Available values are: "native",
        \\"transparent", "tabs", and "hidden".
        \\
        \\The "native" style uses the native macOS titlebar with zero customization.
        \\The titlebar will match your window theme (see `window-theme`).
        \\
        \\The "transparent" style is the same as "native" but the titlebar will
        \\be transparent and allow your window background color to come through.
        \\This makes a more seamless window appearance but looks a little less
        \\typical for a macOS application and may not work well with all themes.
        \\
        \\The "transparent" style will also update in real-time to dynamic
        \\changes to the window background color, e.g. via OSC 11. To make this
        \\more aesthetically pleasing, this only happens if the terminal is
        \\a window, tab, or split that borders the top of the window. This
        \\avoids a disjointed appearance where the titlebar color changes
        \\but all the topmost terminals don't match.
        \\
        \\The "tabs" style is a completely custom titlebar that integrates the
        \\tab bar into the titlebar. This titlebar always matches the background
        \\color of the terminal. There are some limitations to this style:
        \\On macOS 13 and below, saved window state will not restore tabs correctly.
        \\macOS 14 does not have this issue and any other macOS version has not
        \\been tested.
        \\
        \\The "hidden" style hides the titlebar. Unlike `window-decoration = none`,
        \\however, it does not remove the frame from the window or cause it to have
        \\squared corners. Changing to or from this option at run-time may affect
        \\existing windows in buggy ways.
        \\
        \\When "hidden", the top titlebar area can no longer be used for dragging
        \\the window. To drag the window, you can use option+click on the resizable
        \\areas of the frame to drag the window. This is a standard macOS behavior
        \\and not something Ghostty enables.
        \\
        \\The default value is "transparent". This is an opinionated choice
        \\but its one I think is the most aesthetically pleasing and works in
        \\most cases.
        \\
        \\Changing this option at runtime only applies to new windows.
        ,
        .full_zh =
        \\macOS 标题栏的样式。可用值为："native"、"transparent"、"tabs" 和 "hidden"。
        \\
        \\"native" 样式使用原生的 macOS 标题栏，不做任何定制。标题栏会和你的窗口主题一致（见 `window-theme`）。
        \\
        \\"transparent" 样式和 "native" 相同，但标题栏是透明的，能透出你的窗口背景色。这让窗口外观更浑然一体，但看起来不那么像典型的 macOS 应用，也不一定和所有主题都搭。
        \\
        \\"transparent" 样式还会实时跟随窗口背景色的动态变化，例如通过 OSC 11。为了更美观，只有当终端所在的窗口、标签页或分屏紧贴窗口顶部时才会这样。这避免了标题栏颜色变了、最上面的终端却没跟着变的割裂外观。
        \\
        \\"tabs" 样式是一个完全自定义的标题栏，把标签栏并进了标题栏。这个标题栏总是和终端的背景色一致。这种样式有一些限制：在 macOS 13 及更早版本上，保存的窗口状态无法正确恢复标签页。macOS 14 没有这个问题，其他 macOS 版本没有测试过。
        \\
        \\"hidden" 样式隐藏标题栏。不过和 `window-decoration = none` 不同，它不会去掉窗口的边框，也不会让窗口变成直角。在运行时切换到或切换出这个选项，可能会让已有的窗口出现各种问题。
        \\
        \\为 "hidden" 时，顶部的标题栏区域不再能用来拖动窗口。要拖动窗口，可以在边框上可调整大小的区域按 option+点击来拖动。这是 macOS 的标准行为，不是 Ghostty 开启的。
        \\
        \\默认值是 "transparent"。这是一个带主观色彩的选择，但我认为它最美观，而且大多数情况下都适用。
        \\
        \\在运行时修改这个选项，只适用于新窗口。
        ,
    },
    .{
        .key = .@"macos-titlebar-proxy-icon",
        .en = "Whether the proxy icon in the macOS titlebar is visible. The proxy icon is the icon that represents the folder of the current working directory. You can see this very clearly in the macOS built-in Terminal.app titlebar.",
        .zh = "macOS 标题栏里的代理图标是否可见。代理图标表示当前工作目录所在文件夹的图标。在 macOS 自带的“终端”标题栏里能很清楚地看到。",
        .full_en =
        \\Whether the proxy icon in the macOS titlebar is visible. The proxy icon
        \\is the icon that represents the folder of the current working directory.
        \\You can see this very clearly in the macOS built-in Terminal.app
        \\titlebar.
        \\
        \\The proxy icon is only visible with the native macOS titlebar style.
        \\
        \\Valid values are:
        \\
        \\  * `visible` - Show the proxy icon.
        \\  * `hidden` - Hide the proxy icon.
        \\
        \\The default value is `visible`.
        \\
        \\This setting can be changed at runtime and will affect all currently
        \\open windows but only after their working directory changes again.
        \\Therefore, to make this work after changing the setting, you must
        \\usually `cd` to a different directory, open a different file in an
        \\editor, etc.
        ,
        .full_zh =
        \\macOS 标题栏里的代理图标是否可见。代理图标表示当前工作目录所在文件夹的图标。在 macOS 自带的“终端”标题栏里能很清楚地看到。
        \\
        \\代理图标只在原生 macOS 标题栏样式下可见。
        \\
        \\有效值：
        \\
        \\  * `visible`：显示代理图标。
        \\  * `hidden`：隐藏代理图标。
        \\
        \\默认值是 `visible`。
        \\
        \\这项设置可以在运行时修改，会影响所有当前打开的窗口，但要等它们的工作目录再次改变之后。所以修改设置后要让它生效，通常得 `cd` 到另一个目录、在编辑器里打开另一个文件等等。
        ,
    },
    .{
        .key = .@"macos-dock-drop-behavior",
        .en = "Controls the windowing behavior when dropping a file or folder onto the Ghostty icon in the macOS dock.",
        .zh = "控制把文件或文件夹拖放到 macOS 程序坞里的 Ghostty 图标上时的窗口行为。",
        .full_en =
        \\Controls the windowing behavior when dropping a file or folder
        \\onto the Ghostty icon in the macOS dock.
        \\
        \\Valid values are:
        \\
        \\  * `new-tab` - Create a new tab in the current window, or open
        \\    a new window if none exist.
        \\  * `new-window` - Create a new window unconditionally.
        \\
        \\The default value is `new-tab`.
        \\
        \\This setting is only supported on macOS and has no effect on other
        \\platforms.
        ,
        .full_zh =
        \\控制把文件或文件夹拖放到 macOS 程序坞里的 Ghostty 图标上时的窗口行为。
        \\
        \\有效值：
        \\
        \\  * `new-tab`：在当前窗口里新建一个标签页；如果没有窗口，就打开一个新窗口。
        \\  * `new-window`：无条件新建一个窗口。
        \\
        \\默认值是 `new-tab`。
        \\
        \\这项设置只在 macOS 上支持，在其他平台上不起作用。
        ,
    },
    .{
        .key = .@"macos-option-as-alt",
        .en = "macOS doesn't have a distinct \"alt\" key and instead has the \"option\" key which behaves slightly differently. On macOS by default, the option key plus a character will sometimes produce a Unicode character. For example, on US standard layouts option-b produces \"∫\". This may be undesirable if you want to use \"option\" as an \"alt\" key for keybindings in terminal programs or shells.",
        .zh = "macOS 没有单独的 “alt” 键，而是有行为略有不同的 “option” 键。在 macOS 上默认情况下，option 键加一个字符有时会产生 Unicode 字符。例如，在美式标准键盘布局上 option-b 会产生 “∫”。如果你想把 “option” 当作 “alt” 键，用于终端程序或 shell 里的按键绑定，这可能并不合适。",
        .full_en =
        \\macOS doesn't have a distinct "alt" key and instead has the "option"
        \\key which behaves slightly differently. On macOS by default, the
        \\option key plus a character will sometimes produce a Unicode character.
        \\For example, on US standard layouts option-b produces "∫". This may be
        \\undesirable if you want to use "option" as an "alt" key for keybindings
        \\in terminal programs or shells.
        \\
        \\This configuration lets you change the behavior so that option is treated
        \\as alt.
        \\
        \\The default behavior (unset) will depend on your active keyboard
        \\layout. If your keyboard layout is one of the keyboard layouts listed
        \\below, then the default value is "true". Otherwise, the default
        \\value is "false". Keyboard layouts with a default value of "true" are:
        \\
        \\  - U.S. Standard
        \\  - U.S. International
        \\
        \\Note that if an *Option*-sequence doesn't produce a printable character, it
        \\will be treated as *Alt* regardless of this setting. (e.g. `alt+ctrl+a`).
        \\
        \\Explicit values that can be set:
        \\
        \\If `true`, the *Option* key will be treated as *Alt*. This makes terminal
        \\sequences expecting *Alt* to work properly, but will break Unicode input
        \\sequences on macOS if you use them via the *Alt* key.
        \\
        \\You may set this to `false` to restore the macOS *Alt* key unicode
        \\sequences but this will break terminal sequences expecting *Alt* to work.
        \\
        \\The values `left` or `right` enable this for the left or right *Option*
        \\key, respectively.
        ,
        .full_zh =
        \\macOS 没有单独的 “alt” 键，而是有行为略有不同的 “option” 键。在 macOS 上默认情况下，option 键加一个字符有时会产生 Unicode 字符。例如，在美式标准键盘布局上 option-b 会产生 “∫”。如果你想把 “option” 当作 “alt” 键，用于终端程序或 shell 里的按键绑定，这可能并不合适。
        \\
        \\这项配置让你改变这一行为，把 option 当作 alt。
        \\
        \\默认行为（不设置）取决于你当前的键盘布局。如果你的键盘布局是下面列出的之一，默认值就是 "true"；否则默认值是 "false"。默认值为 "true" 的键盘布局有：
        \\
        \\  - 美式标准（U.S. Standard）
        \\  - 美式国际（U.S. International）
        \\
        \\注意，如果一个 *Option* 组合没有产生可打印字符，不管这项怎么设，都会被当作 *Alt*（例如 `alt+ctrl+a`）。
        \\
        \\可以明确设置的值：
        \\
        \\设为 `true` 时，*Option* 键会被当作 *Alt*。这让期望 *Alt* 的终端序列能正常工作，但如果你通过 *Alt* 键输入 macOS 的 Unicode 字符，那些输入就不能用了。
        \\
        \\可以设为 `false`，恢复 macOS 上 *Alt* 键的 Unicode 输入，但这样期望 *Alt* 的终端序列就不能正常工作了。
        \\
        \\值 `left` 或 `right` 分别只为左边或右边的 *Option* 键启用这一行为。
        ,
    },
    .{ .key = .@"macos-window-shadow", .en = "Whether to enable the macOS window shadow. The default value is true. With some window managers and window transparency settings, you may find false more visually appealing.", .zh = "是否启用 macOS 窗口阴影。默认值为 true。在某些窗口管理器和窗口透明度设置下，设为 false 可能在视觉上更好看。" },
    .{
        .key = .@"macos-hidden",
        .en = "If true, the macOS icon in the dock and app switcher will be hidden. This is mainly intended for those primarily using the quick-terminal mode.",
        .zh = "设为 true 时，隐藏程序坞和应用切换器中的 macOS 图标。主要面向主要使用快速终端模式的用户。",
        .full_en =
        \\If true, the macOS icon in the dock and app switcher will be hidden. This is
        \\mainly intended for those primarily using the quick-terminal mode.
        \\
        \\Note that setting this to true means that keyboard layout changes
        \\will no longer be automatic.
        \\
        \\Control whether macOS app is excluded from the dock and app switcher,
        \\a "hidden" state. This is mainly intended for those primarily using
        \\quick-terminal mode, but is a general configuration for any use
        \\case.
        \\
        \\Available values:
        \\
        \\  * `never` - The macOS app is never hidden.
        \\  * `always` - The macOS app is always hidden.
        \\
        \\Note: When the macOS application is hidden, keyboard layout changes
        \\will no longer be automatic. This is a limitation of macOS.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\设为 true 时，隐藏程序坞和应用切换器中的 macOS 图标。主要面向主要使用快速终端模式的用户。
        \\
        \\注意，设为 true 意味着键盘布局的切换不再是自动的。
        \\
        \\控制 macOS 应用是否从程序坞和应用切换器中隐去，也就是“隐藏”状态。这主要面向主要使用快速终端模式的用户，但它是一项通用配置，适用于任何场景。
        \\
        \\可用值：
        \\
        \\  * `never`：macOS 应用从不隐藏。
        \\  * `always`：macOS 应用总是隐藏。
        \\
        \\注意：macOS 应用隐藏时，键盘布局的切换不再是自动的。这是 macOS 的限制。
        \\
        \\自 1.2.0 起可用。
        ,
    },
    .{
        .key = .@"macos-auto-secure-input",
        .en = "If true, Ghostty on macOS will automatically enable the \"Secure Input\" feature when it detects that a password prompt is being displayed.",
        .zh = "设为 true 时，macOS 上的 Ghostty 检测到正在显示密码提示符时，会自动启用“安全输入”功能。",
        .full_en =
        \\If true, Ghostty on macOS will automatically enable the "Secure Input"
        \\feature when it detects that a password prompt is being displayed.
        \\
        \\"Secure Input" is a macOS security feature that prevents applications from
        \\reading keyboard events. This can always be enabled manually using the
        \\`Ghostty > Secure Keyboard Entry` menu item.
        \\
        \\Note that automatic password prompt detection is based on heuristics
        \\and may not always work as expected. Specifically, it does not work
        \\over SSH connections, but there may be other cases where it also
        \\doesn't work.
        \\
        \\A reason to disable this feature is if you find that it is interfering
        \\with legitimate accessibility software (or software that uses the
        \\accessibility APIs), since secure input prevents any application from
        \\reading keyboard events.
        ,
        .full_zh =
        \\设为 true 时，macOS 上的 Ghostty 检测到正在显示密码提示符时，会自动启用“安全输入”功能。
        \\
        \\“安全输入”是 macOS 的一项安全功能，防止应用读取键盘事件。也可以随时通过菜单项 `Ghostty > Secure Keyboard Entry` 手动启用。
        \\
        \\注意，密码提示符的自动检测基于启发式判断，不一定总能按预期工作。具体来说，它在 SSH 连接上不起作用，也可能还有其他不起作用的情况。
        \\
        \\关闭这项功能的一个理由是：你发现它干扰了正当的辅助功能软件（或使用辅助功能 API 的软件），因为安全输入会阻止任何应用读取键盘事件。
        ,
    },
    .{
        .key = .@"macos-secure-input-indication",
        .en = "If true, Ghostty will show a graphical indication when secure input is enabled. This indication is generally recommended to know when secure input is enabled.",
        .zh = "设为 true 时，启用安全输入后 Ghostty 会显示图形提示。一般建议保留这个提示，以便知道安全输入何时开启。",
        .full_en =
        \\If true, Ghostty will show a graphical indication when secure input is
        \\enabled. This indication is generally recommended to know when secure input
        \\is enabled.
        \\
        \\Normally, secure input is only active when a password prompt is displayed
        \\or it is manually (and typically temporarily) enabled. However, if you
        \\always have secure input enabled, the indication can be distracting and
        \\you may want to disable it.
        ,
        .full_zh =
        \\设为 true 时，启用安全输入后 Ghostty 会显示图形提示。一般建议保留这个提示，以便知道安全输入何时开启。
        \\
        \\通常，安全输入只在显示密码提示符时，或者被手动（通常是临时地）启用时才生效。不过，如果你一直开着安全输入，这个提示可能会让人分心，你也许想关掉它。
        ,
    },
    .{
        .key = .@"windows-secure-input-exclude-from-capture",
        .en = "Keep the window out of screen captures while secure input is on.",
        .zh = "安全输入开启期间，让窗口不出现在屏幕捕获中。",
        .full_en =
        \\Keep the window out of screen captures while secure input is on.
        \\
        \\When true, Windows is asked for `WDA_EXCLUDEFROMCAPTURE` on the terminal
        \\window for as long as any surface in it has secure input enabled, and the
        \\window is restored to `WDA_NONE` when the last one leaves. A capture --
        \\a screenshot, a screen share, a recording -- sees black where the window
        \\is; the window is unchanged on the physical screen.
        \\
        \\This is the Windows counterpart to what `macos-auto-secure-input`
        \\protects: a password prompt that nobody can read the keys of is still
        \\readable if it is on somebody's shared screen.
        \\
        \\**This only hides pixels.** It does not affect the accessibility tree:
        \\UI Automation still reports the window, its tabs and its terminals while
        \\the protection is on, which is measured and deliberate -- a screen reader
        \\must not go silent at a password prompt. Anything that drives this
        \\terminal by reading its accessibility tree keeps working; anything that
        \\drives it by looking at pixels does not.
        \\
        \\A reason to turn this off is that it makes a terminal impossible to
        \\screenshot at exactly the moment somebody is trying to record a bug.
        \\
        \\Only has an effect on Windows.
        ,
        .full_zh =
        \\安全输入开启期间，让窗口不出现在屏幕捕获中。
        \\
        \\设为 true 时，只要终端窗口里有任何终端启用了安全输入，就请求 Windows 对该窗口使用 `WDA_EXCLUDEFROMCAPTURE`；最后一个离开安全输入时，窗口恢复为 `WDA_NONE`。屏幕捕获（截图、屏幕共享、录屏）在窗口的位置只看到一片黑；物理屏幕上的窗口不受影响。
        \\
        \\这是 Windows 上对应 `macos-auto-secure-input` 所保护的那件事：一个谁都读不到按键的密码提示符，如果出现在某人共享的屏幕上，仍然看得见。
        \\
        \\**这只隐藏像素。** 它不影响辅助功能树：保护开着时，UI Automation 照样报告这个窗口、它的标签页和它的终端，这是实测过的、有意为之的：读屏软件不能在密码提示符前变哑。凡是靠读辅助功能树来驱动这个终端的，照常工作；靠看像素来驱动的，就不行了。
        \\
        \\关闭它的一个理由是：它恰恰在有人想录下一个 bug 的那一刻，让终端无法截图。
        \\
        \\只在 Windows 上有效。
        ,
    },
    .{
        .key = .@"windows-console-utf8",
        .en = "Switch the console of each new terminal to UTF-8 (code page 65001).",
        .zh = "把每个新终端的控制台切换到 UTF-8（代码页 65001）。",
        .full_en =
        \\Switch the console of each new terminal to UTF-8 (code page 65001).
        \\
        \\On a Chinese, Japanese or Korean Windows the console starts in the
        \\system's legacy code page (936 for Simplified Chinese), and programs that
        \\write UTF-8 -- `git`, Python, anything built with Rust or Go -- show up as
        \\mojibake. Windows PowerShell also passes text to other programs as ASCII,
        \\so Chinese in a pipeline arrives as `?`.
        \\
        \\When true, PowerShell sets its console input, console output and pipeline
        \\encodings to UTF-8 as the shell integration loads, and `cmd.exe` is
        \\started with `chcp 65001`. Only the terminal Polter started is changed:
        \\your PowerShell profile, the registry and the system-wide UTF-8 setting
        \\are left alone, and a console opened outside Polter is as it was.
        \\
        \\For PowerShell this needs shell integration: with
        \\`shell-integration = none`, or a `command` that passes its own `-Command`,
        \\nothing is changed and the log says so. `cmd.exe` is only changed when
        \\it is started with no arguments of its own.
        \\
        \\A reason to turn this off is an old program that writes text in the
        \\legacy code page, which shows up as mojibake once the console is UTF-8.
        \\
        \\Python reads text piped into it in the legacy code page whatever the
        \\console says; run it with `-X utf8`, or set `PYTHONUTF8=1`, for it to
        \\read UTF-8 there.
        \\
        \\Only has an effect on Windows.
        ,
        .full_zh =
        \\把每个新终端的控制台切换到 UTF-8（代码页 65001）。
        \\
        \\中文、日文或韩文 Windows 上，控制台一开始用的是系统的旧代码页（简体中文是 936），于是输出 UTF-8 的程序——`git`、Python、用 Rust 或 Go 写的程序——显示成乱码。Windows PowerShell 还会用 ASCII 把文字传给别的程序，管道里的中文到了对面变成 `?`。
        \\
        \\设为 true 时，PowerShell 在加载 shell 集成时把控制台输入、控制台输出和管道的编码都设成 UTF-8，`cmd.exe` 则带着 `chcp 65001` 启动。只改 Polter 启动的这个终端：你的 PowerShell 配置文件、注册表和系统级的 UTF-8 设置都不动，在 Polter 以外打开的控制台也照旧。
        \\
        \\PowerShell 要靠 shell 集成才能切换：设了 `shell-integration = none`，或者 `command` 自带 `-Command` 时，什么都不改，日志里会说明。`cmd.exe` 只有在不带自己的参数启动时才会改。
        \\
        \\要关掉它的一个理由是：某个老程序按旧代码页输出文字，控制台换成 UTF-8 以后它会变成乱码。
        \\
        \\Python 读管道里传进来的文字时，不管控制台是什么代码页，都按旧代码页解码；要它在这里读 UTF-8，用 `-X utf8` 运行，或者设置 `PYTHONUTF8=1`。
        \\
        \\仅在 Windows 上生效。
        ,
    },
    .{
        .key = .@"macos-applescript",
        .en = "If true, Ghostty exposes and handles the built-in AppleScript dictionary on macOS.",
        .zh = "设为 true 时，Ghostty 在 macOS 上提供并处理内置的 AppleScript 词典。",
        .full_en =
        \\If true, Ghostty exposes and handles the built-in AppleScript dictionary
        \\on macOS.
        \\
        \\If false, all AppleScript interactions are disabled. This includes
        \\AppleScript commands and AppleScript object lookup for windows, tabs,
        \\and terminals.
        \\
        \\The default is true.
        ,
        .full_zh =
        \\设为 true 时，Ghostty 在 macOS 上提供并处理内置的 AppleScript 词典。
        \\
        \\设为 false 时，停用所有 AppleScript 交互，包括 AppleScript 命令，以及对窗口、标签页和终端的 AppleScript 对象查找。
        \\
        \\默认为 true。
        ,
    },
    .{
        .key = .@"macos-icon",
        .en = "Customize the macOS app icon.",
        .zh = "自定义 macOS 应用图标。",
        .full_en =
        \\Customize the macOS app icon.
        \\
        \\This only affects the icon that appears in the dock, application
        \\switcher, etc. This does not affect the icon in Finder because
        \\that is controlled by a hardcoded value in the signed application
        \\bundle and can't be changed at runtime. For more details on what
        \\exactly is affected, see the `NSApplication.icon` Apple documentation;
        \\that is the API that is being used to set the icon.
        \\
        \\Valid values:
        \\
        \\ * `official` - Use the official Ghostty icon.
        \\ * `blueprint`, `chalkboard`, `microchip`, `glass`, `holographic`,
        \\   `paper`, `retro`, `xray` - Official variants of the Ghostty icon
        \\   hand-created by artists (no AI).
        \\ * `custom` - Use a completely custom icon. The location must be specified
        \\   using the additional `macos-custom-icon` configuration
        \\ * `custom-style` - Use the official Ghostty icon but with custom
        \\   styles applied to various layers. The custom styles must be
        \\   specified using the additional `macos-icon`-prefixed configurations.
        \\   The `macos-icon-ghost-color` and `macos-icon-screen-color`
        \\   configurations are required for this style.
        \\
        \\WARNING: The `custom-style` option is _experimental_. We may change
        \\the format of the custom styles in the future. We're still finalizing
        \\the exact layers and customization options that will be available.
        \\
        \\Other caveats:
        \\
        \\  * The icon in the update dialog will always be the official icon.
        \\    This is because the update dialog is managed through a
        \\    separate framework and cannot be customized without significant
        \\    effort.
        ,
        .full_zh =
        \\自定义 macOS 应用图标。
        \\
        \\这只影响出现在程序坞、应用切换器等处的图标，不影响访达里的图标，因为那由已签名应用包里写死的值控制，不能在运行时修改。关于具体影响哪些地方，详见 Apple 文档里的 `NSApplication.icon`；设置图标用的就是这个 API。
        \\
        \\有效值：
        \\
        \\ * `official`：使用官方 Ghostty 图标。
        \\ * `blueprint`、`chalkboard`、`microchip`、`glass`、`holographic`、`paper`、`retro`、`xray`：由画师手工绘制（没有使用 AI）的 Ghostty 官方图标变体。
        \\ * `custom`：使用完全自定义的图标。位置必须用另一项配置 `macos-custom-icon` 指定
        \\ * `custom-style`：使用官方 Ghostty 图标，但对各个图层应用自定义样式。自定义样式必须用其他以 `macos-icon` 开头的配置指定。这种样式要求设置 `macos-icon-ghost-color` 和 `macos-icon-screen-color` 两项配置。
        \\
        \\警告：`custom-style` 选项是_实验性_的。以后我们可能会改变自定义样式的格式。具体会提供哪些图层和定制选项，我们还在最终敲定。
        \\
        \\其他注意事项：
        \\
        \\  * 更新对话框里的图标始终是官方图标。这是因为更新对话框由一个单独的框架管理，不费很大力气就无法定制。
        ,
    },
    .{
        .key = .@"macos-custom-icon",
        .en = "The absolute path to the custom icon file. Supported formats include PNG, JPEG, and ICNS.",
        .zh = "自定义图标文件的绝对路径。支持 PNG、JPEG 和 ICNS 格式。",
        .full_en =
        \\The absolute path to the custom icon file.
        \\Supported formats include PNG, JPEG, and ICNS.
        \\
        \\Defaults to `~/.config/ghostty/Ghostty.icns`
        ,
        .full_zh =
        \\自定义图标文件的绝对路径。支持 PNG、JPEG 和 ICNS 格式。
        \\
        \\默认为 `~/.config/ghostty/Ghostty.icns`
        ,
    },
    .{
        .key = .@"macos-icon-frame",
        .en = "The material to use for the frame of the macOS app icon.",
        .zh = "macOS 应用图标边框所用的材质。",
        .full_en =
        \\The material to use for the frame of the macOS app icon.
        \\
        \\Valid values:
        \\
        \\ * `aluminum` - A brushed aluminum frame. This is the default.
        \\ * `beige` - A classic 90's computer beige frame.
        \\ * `plastic` - A glossy, dark plastic frame.
        \\ * `chrome` - A shiny chrome frame.
        \\
        \\Note: This configuration is required when `macos-icon` is set to
        \\`custom-style`.
        ,
        .full_zh =
        \\macOS 应用图标边框所用的材质。
        \\
        \\有效值：
        \\
        \\ * `aluminum`：拉丝铝边框。这是默认值。
        \\ * `beige`：90 年代经典的米色电脑边框。
        \\ * `plastic`：有光泽的深色塑料边框。
        \\ * `chrome`：闪亮的镀铬边框。
        \\
        \\注意：`macos-icon` 设为 `custom-style` 时，必须设置这项配置。
        ,
    },
    .{
        .key = .@"macos-icon-ghost-color",
        .en = "The color of the ghost in the macOS app icon.",
        .zh = "macOS 应用图标中幽灵的颜色。",
        .full_en =
        \\The color of the ghost in the macOS app icon.
        \\
        \\Note: This configuration is required when `macos-icon` is set to
        \\`custom-style`.
        \\
        \\Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.
        ,
        .full_zh =
        \\macOS 应用图标中幽灵的颜色。
        \\
        \\注意：`macos-icon` 设为 `custom-style` 时，必须设置这项配置。
        \\
        \\可写成十六进制（`#RRGGBB` 或 `RRGGBB`），或 X11 颜色名。
        ,
    },
    .{
        .key = .@"macos-icon-screen-color",
        .en = "The color of the screen in the macOS app icon.",
        .zh = "macOS 应用图标中屏幕的颜色。",
        .full_en =
        \\The color of the screen in the macOS app icon.
        \\
        \\The screen is a linear gradient so you can specify multiple colors
        \\that make up the gradient. Up to 64 comma-separated colors may be
        \\specified as either hex (`#RRGGBB` or `RRGGBB`) or as named X11
        \\colors. The first color is the bottom of the gradient and the last
        \\color is the top of the gradient.
        \\
        \\Note: This configuration is required when `macos-icon` is set to
        \\`custom-style`.
        ,
        .full_zh =
        \\macOS 应用图标中屏幕的颜色。
        \\
        \\屏幕是一个线性渐变，所以可以指定构成渐变的多种颜色。最多可以指定 64 种用逗号分隔的颜色，写成十六进制（`#RRGGBB` 或 `RRGGBB`）或 X11 颜色名。第一种颜色是渐变的底部，最后一种颜色是渐变的顶部。
        \\
        \\注意：`macos-icon` 设为 `custom-style` 时，必须设置这项配置。
        ,
    },
    .{
        .key = .@"macos-shortcuts",
        .en = "Whether macOS Shortcuts are allowed to control Ghostty.",
        .zh = "是否允许 macOS“快捷指令”控制 Ghostty。",
        .full_en =
        \\Whether macOS Shortcuts are allowed to control Ghostty.
        \\
        \\Ghostty exposes a number of actions that allow Shortcuts to
        \\control and interact with Ghostty. This includes creating new
        \\terminals, sending text to terminals, running commands, invoking
        \\any keybind action, etc.
        \\
        \\This is a powerful feature but can be a security risk if a malicious
        \\shortcut is able to be installed and executed. Therefore, this
        \\configuration allows you to disable this feature.
        \\
        \\Valid values are:
        \\
        \\* `ask` - Ask the user whether for permission. Ghostty will remember
        \\  this choice and never ask again. This is similar to other macOS
        \\  permissions such as microphone access, camera access, etc.
        \\
        \\* `allow` - Allow Shortcuts to control Ghostty without asking.
        \\
        \\* `deny` - Deny Shortcuts from controlling Ghostty.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\是否允许 macOS“快捷指令”控制 Ghostty。
        \\
        \\Ghostty 提供了许多动作，允许快捷指令控制 Ghostty 并与之交互，包括创建新终端、向终端发送文本、运行命令、调用任意按键绑定动作等。
        \\
        \\这是一项强大的功能，但如果恶意的快捷指令能被安装和执行，就可能有安全风险。所以这项配置让你可以停用这个功能。
        \\
        \\有效值：
        \\
        \\* `ask`：询问用户是否授予权限。Ghostty 会记住这个选择，以后不再询问。这和麦克风、摄像头等其他 macOS 权限类似。
        \\
        \\* `allow`：允许快捷指令控制 Ghostty，不再询问。
        \\
        \\* `deny`：拒绝快捷指令控制 Ghostty。
        \\
        \\自 1.2.0 起可用。
        ,
    },
    .{
        .key = .@"linux-cgroup",
        .en = "Put every surface (tab, split, window) into a transient `systemd` scope.",
        .zh = "把每个终端（标签页、分屏、窗口）放进临时的 `systemd` scope。",
        .full_en =
        \\Put every surface (tab, split, window) into a transient `systemd` scope.
        \\
        \\This allows per-surface resource management. For example, if a shell program
        \\is using too much memory, only that shell will be killed by the oom monitor
        \\instead of the entire Ghostty process. Similarly, if a shell program is
        \\using too much CPU, only that surface will be CPU-throttled.
        \\
        \\This will cause startup times to be slower (a hundred milliseconds or so),
        \\so the default value is "single-instance." In single-instance mode, only
        \\one instance of Ghostty is running (see gtk-single-instance) so the startup
        \\time is a one-time cost. Additionally, single instance Ghostty is much
        \\more likely to have many windows, tabs, etc. so cgroup isolation is a
        \\big benefit.
        \\
        \\This feature requires `systemd`. If `systemd` is unavailable, cgroup
        \\initialization will fail. By default, this will not prevent Ghostty from
        \\working (see `linux-cgroup-hard-fail`).
        \\
        \\Changing this value and reloading the config will not affect existing
        \\surfaces.
        \\
        \\Valid values are:
        \\
        \\  * `never` - Never use cgroups.
        \\  * `always` - Always use cgroups.
        \\  * `single-instance` - Enable cgroups only for Ghostty instances launched
        \\    as single-instance applications (see gtk-single-instance).
        ,
        .full_zh =
        \\把每个终端（标签页、分屏、窗口）放进临时的 `systemd` scope。
        \\
        \\这样可以按终端管理资源。例如，如果某个 shell 程序占用内存太多，oom 监视器只会杀掉那个 shell，而不是整个 Ghostty 进程。同样，如果某个 shell 程序占用 CPU 太多，只有那个终端会被限制 CPU。
        \\
        \\这会让启动变慢（大约一百毫秒），所以默认值是 "single-instance"。在单实例模式下，只有一个 Ghostty 实例在运行（见 gtk-single-instance），所以启动时间只是一次性的代价。此外，单实例的 Ghostty 更可能有很多窗口、标签页等，所以 cgroup 隔离的好处很大。
        \\
        \\这项功能需要 `systemd`。`systemd` 不可用时，cgroup 初始化会失败。默认情况下，这不会妨碍 Ghostty 工作（见 `linux-cgroup-hard-fail`）。
        \\
        \\修改这个值并重新加载配置，不会影响已有的终端。
        \\
        \\有效值：
        \\
        \\  * `never`：从不使用 cgroup。
        \\  * `always`：总是使用 cgroup。
        \\  * `single-instance`：只为以单实例应用启动的 Ghostty 实例启用 cgroup（见 gtk-single-instance）。
        ,
    },
    .{
        .key = .@"linux-cgroup-memory-limit",
        .en = "Memory limit for any individual terminal process (tab, split, window, etc.) in bytes. If this is unset then no memory limit will be set.",
        .zh = "任一单个终端进程（标签页、分屏、窗口等）的内存上限，单位为字节。不设置则不限制内存。",
        .full_en =
        \\Memory limit for any individual terminal process (tab, split, window,
        \\etc.) in bytes. If this is unset then no memory limit will be set.
        \\
        \\Note that this sets the `MemoryHigh` setting on the transient `systemd`
        \\scope, which is a soft limit. You should configure something like
        \\`systemd-oom` to handle killing processes that have too much memory
        \\pressure.
        \\
        \\Changing this value and reloading the config will not affect existing
        \\surfaces.
        \\
        \\See the `systemd.resource-control` manual page for more information:
        \\https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
        ,
        .full_zh =
        \\任一单个终端进程（标签页、分屏、窗口等）的内存上限，单位为字节。不设置则不限制内存。
        \\
        \\注意，这设置的是临时 `systemd` scope 上的 `MemoryHigh`，是一个软上限。你应该配置 `systemd-oom` 之类的东西，来处理杀掉内存压力过大的进程。
        \\
        \\修改这个值并重新加载配置，不会影响已有的终端。
        \\
        \\更多信息见 `systemd.resource-control` 手册页：https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
        ,
    },
    .{
        .key = .@"linux-cgroup-processes-limit",
        .en = "Number of processes limit for any individual terminal process (tab, split, window, etc.). If this is unset then no limit will be set.",
        .zh = "任一单个终端进程（标签页、分屏、窗口等）的进程数上限。不设置则不限制。",
        .full_en =
        \\Number of processes limit for any individual terminal process (tab, split,
        \\window, etc.). If this is unset then no limit will be set.
        \\
        \\Note that this sets the `TasksMax` setting on the transient `systemd` scope,
        \\which is a hard limit.
        \\
        \\Changing this value and reloading the config will not affect existing
        \\surfaces.
        \\
        \\See the `systemd.resource-control` manual page for more information:
        \\https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
        ,
        .full_zh =
        \\任一单个终端进程（标签页、分屏、窗口等）的进程数上限。不设置则不限制。
        \\
        \\注意，这设置的是临时 `systemd` scope 上的 `TasksMax`，是一个硬上限。
        \\
        \\修改这个值并重新加载配置，不会影响已有的终端。
        \\
        \\更多信息见 `systemd.resource-control` 手册页：https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
        ,
    },
    .{
        .key = .@"linux-cgroup-hard-fail",
        .en = "If this is false, then creating a transient `systemd` scope (for `linux-cgroup`) will be allowed to fail and the failure is ignored. This is useful if you view cgroup isolation as a \"nice to have\" and not a critical resource management feature, because surface creation will not fail if `systemd` APIs fail.",
        .zh = "设为 false 时，创建临时 `systemd` scope（用于 `linux-cgroup`）允许失败，失败会被忽略。如果你把 cgroup 隔离看作“有最好、没有也行”，而不是关键的资源管理功能，这很有用，因为 `systemd` API 失败时，终端的创建不会随之失败。",
        .full_en =
        \\If this is false, then creating a transient `systemd` scope (for
        \\`linux-cgroup`) will be allowed to fail and the failure is ignored. This is
        \\useful if you view cgroup isolation as a "nice to have" and not a critical
        \\resource management feature, because surface creation will not fail if
        \\`systemd` APIs fail.
        \\
        \\If this is true, then any transient `systemd` scope creation failure will
        \\cause surface creation to fail.
        \\
        \\Changing this value and reloading the config will not affect existing
        \\surfaces.
        ,
        .full_zh =
        \\设为 false 时，创建临时 `systemd` scope（用于 `linux-cgroup`）允许失败，失败会被忽略。如果你把 cgroup 隔离看作“有最好、没有也行”，而不是关键的资源管理功能，这很有用，因为 `systemd` API 失败时，终端的创建不会随之失败。
        \\
        \\设为 true 时，任何临时 `systemd` scope 创建失败，都会导致终端创建失败。
        \\
        \\修改这个值并重新加载配置，不会影响已有的终端。
        ,
    },
    .{
        .key = .@"gtk-opengl-debug",
        .en = "Enable or disable GTK's OpenGL debugging logs. The default is `true` for debug builds, `false` for all others.",
        .zh = "启用或禁用 GTK 的 OpenGL 调试日志。调试构建默认为 `true`，其他构建默认为 `false`。",
        .full_en =
        \\Enable or disable GTK's OpenGL debugging logs. The default is `true` for
        \\debug builds, `false` for all others.
        \\
        \\Available since: 1.1.0
        ,
        .full_zh =
        \\启用或禁用 GTK 的 OpenGL 调试日志。调试构建默认为 `true`，其他构建默认为 `false`。
        \\
        \\自 1.1.0 起可用。
        ,
    },
    .{
        .key = .@"gtk-single-instance",
        .en = "If `true`, the Ghostty GTK application will run in single-instance mode: each new `ghostty` process launched will result in a new window if there is already a running process.",
        .zh = "为 `true` 时，Ghostty GTK 应用以单实例模式运行：已有进程在运行时，每启动一个新的 `ghostty` 进程，都会得到一个新窗口。",
        .full_en =
        \\If `true`, the Ghostty GTK application will run in single-instance mode:
        \\each new `ghostty` process launched will result in a new window if there is
        \\already a running process.
        \\
        \\If `false`, each new ghostty process will launch a separate application.
        \\
        \\If `detect`, Ghostty will assume true (single instance) unless one of
        \\the following scenarios is found:
        \\
        \\1. TERM_PROGRAM environment variable is a non-empty value. In this
        \\case, we assume Ghostty is being launched from a graphical terminal
        \\session and you want a dedicated instance.
        \\
        \\2. Any CLI arguments exist. In this case, we assume you are passing
        \\custom Ghostty configuration. Single instance mode inherits the
        \\configuration from when it was launched, so we must disable single
        \\instance to load the new configuration.
        \\
        \\If either of these scenarios is producing a false positive, you can
        \\set this configuration explicitly to the behavior you want.
        \\
        \\The pre-1.2 option `desktop` has been deprecated. Please replace
        \\this with `detect`.
        \\
        \\The default value is `detect`.
        \\
        \\Note that debug builds of Ghostty have a separate single-instance ID
        \\so you can test single instance without conflicting with release builds.
        ,
        .full_zh =
        \\为 `true` 时，Ghostty GTK 应用以单实例模式运行：已有进程在运行时，每启动一个新的 `ghostty` 进程，都会得到一个新窗口。
        \\
        \\为 `false` 时，每个新的 ghostty 进程都会启动一个独立的应用。
        \\
        \\为 `detect` 时，Ghostty 会假定为 true（单实例），除非遇到以下情况之一：
        \\
        \\1. 环境变量 TERM_PROGRAM 是非空值。这种情况下，我们认为 Ghostty 是从一个图形终端会话里启动的，而你想要一个专用的实例。
        \\
        \\2. 有任何命令行参数。这种情况下，我们认为你在传入自定义的 Ghostty 配置。单实例模式沿用的是它启动时的配置，所以必须停用单实例，才能加载新的配置。
        \\
        \\如果其中任何一种情况造成了误判，你可以明确地把这项配置设成你想要的行为。
        \\
        \\1.2 之前的选项 `desktop` 已弃用。请改用 `detect`。
        \\
        \\默认值是 `detect`。
        \\
        \\注意，Ghostty 的调试构建有一个单独的单实例 ID，这样你测试单实例时不会和正式发布版冲突。
        ,
    },
    .{
        .key = .@"gtk-titlebar",
        .en = "When enabled, the full GTK titlebar is displayed instead of your window manager's simple titlebar. The behavior of this option will vary with your window manager.",
        .zh = "启用时，显示完整的 GTK 标题栏，而不是窗口管理器的简易标题栏。这个选项的行为会因窗口管理器而异。",
        .full_en =
        \\When enabled, the full GTK titlebar is displayed instead of your window
        \\manager's simple titlebar. The behavior of this option will vary with your
        \\window manager.
        \\
        \\This option does nothing when `window-decoration` is none or when running
        \\under macOS.
        ,
        .full_zh =
        \\启用时，显示完整的 GTK 标题栏，而不是窗口管理器的简易标题栏。这个选项的行为会因窗口管理器而异。
        \\
        \\`window-decoration` 为 none 时，或在 macOS 下运行时，这个选项不起作用。
        ,
    },
    .{
        .key = .@"gtk-tabs-location",
        .en = "Determines the side of the screen that the GTK tab bar will stick to. Top, bottom, and hidden are supported. The default is top.",
        .zh = "决定 GTK 标签栏贴靠屏幕的哪一侧。支持顶部、底部和隐藏。默认为顶部。",
        .full_en =
        \\Determines the side of the screen that the GTK tab bar will stick to.
        \\Top, bottom, and hidden are supported. The default is top.
        \\
        \\When `hidden` is set, a tab button displaying the number of tabs will appear
        \\in the title bar. It has the ability to open a tab overview for displaying
        \\tabs. Alternatively, you can use the `toggle_tab_overview` action in a
        \\keybind if your window doesn't have a title bar, or you can switch tabs
        \\with keybinds.
        ,
        .full_zh =
        \\决定 GTK 标签栏贴靠屏幕的哪一侧。支持顶部、底部和隐藏。默认为顶部。
        \\
        \\设为 `hidden` 时，标题栏里会出现一个显示标签页数量的标签按钮。它可以打开标签页概览来显示标签页。另外，如果你的窗口没有标题栏，可以在按键绑定里使用 `toggle_tab_overview` 动作，也可以用按键绑定切换标签页。
        ,
    },
    .{
        .key = .@"gtk-titlebar-hide-when-maximized",
        .en = "If this is `true`, the titlebar will be hidden when the window is maximized, and shown when the titlebar is unmaximized. GTK only.",
        .zh = "为 `true` 时，窗口最大化后隐藏标题栏，取消最大化后再显示。仅限 GTK。",
        .full_en =
        \\If this is `true`, the titlebar will be hidden when the window is maximized,
        \\and shown when the titlebar is unmaximized. GTK only.
        \\
        \\Available since: 1.1.0
        ,
        .full_zh =
        \\为 `true` 时，窗口最大化后隐藏标题栏，取消最大化后再显示。仅限 GTK。
        \\
        \\自 1.1.0 起可用。
        ,
    },
    .{
        .key = .@"gtk-toolbar-style",
        .en = "Determines the appearance of the top and bottom bars tab bar.",
        .zh = "决定顶部和底部标签栏的外观。",
        .full_en =
        \\Determines the appearance of the top and bottom bars tab bar.
        \\
        \\Valid values are:
        \\
        \\ * `flat` - Top and bottom bars are flat with the terminal window.
        \\ * `raised` - Top and bottom bars cast a shadow on the terminal area.
        \\ * `raised-border` - Similar to `raised` but the shadow is replaced with a
        \\   more subtle border.
        ,
        .full_zh =
        \\决定顶部和底部标签栏的外观。
        \\
        \\有效值：
        \\
        \\ * `flat`：顶部和底部的栏与终端窗口齐平。
        \\ * `raised`：顶部和底部的栏在终端区域上投下阴影。
        \\ * `raised-border`：和 `raised` 类似，但阴影换成了更含蓄的边框。
        ,
    },
    .{
        .key = .@"gtk-titlebar-style",
        .en = "The style of the GTK titlebar. Available values are `native` and `tabs`.",
        .zh = "GTK 标题栏的样式。可用值为 `native` 和 `tabs`。",
        .full_en =
        \\The style of the GTK titlebar. Available values are `native` and `tabs`.
        \\
        \\The `native` titlebar style is a traditional titlebar with a title, a few
        \\buttons and window controls. A separate tab bar will show up below the
        \\titlebar if you have multiple tabs open in the window.
        \\
        \\The `tabs` titlebar merges the tab bar and the traditional titlebar.
        \\This frees up vertical space on your screen if you use multiple tabs. One
        \\limitation of the `tabs` titlebar is that you cannot drag the titlebar
        \\by the titles any longer (as they are tab titles now). Other areas of the
        \\`tabs` title bar can be used to drag the window around.
        \\
        \\The default style is `native`.
        ,
        .full_zh =
        \\GTK 标题栏的样式。可用值为 `native` 和 `tabs`。
        \\
        \\`native` 标题栏样式是传统的标题栏，有标题、几个按钮和窗口控件。窗口里开了多个标签页时，标题栏下方会出现一条单独的标签栏。
        \\
        \\`tabs` 标题栏把标签栏和传统标题栏合在一起。如果你用多个标签页，这能腾出屏幕上的垂直空间。`tabs` 标题栏的一个限制是，不能再通过标题拖动标题栏（因为它们现在是标签页的标题）。`tabs` 标题栏的其他区域可以用来拖动窗口。
        \\
        \\默认样式是 `native`。
        ,
    },
    .{ .key = .@"gtk-wide-tabs", .en = "If `true` (default), then the Ghostty GTK tabs will be \"wide.\" Wide tabs are the new typical Gnome style where tabs fill their available space. If you set this to `false` then tabs will only take up space they need, which is the old style.", .zh = "为 `true`（默认）时，Ghostty GTK 标签页是“宽”的。宽标签页是新的 Gnome 典型样式，标签页会占满可用空间。设为 `false` 时，标签页只占用所需的空间，这是旧样式。" },
    .{
        .key = .@"gtk-horizontal-tab-scroll",
        .en = "If `true` (default), then two-finger horizontal scrolling on a touchpad will switch between tabs. Scrolling left goes to the next tab and scrolling right goes to the previous tab. Set this to `false` to disable this behavior.",
        .zh = "为 `true`（默认）时，在触控板上用两指横向滚动可切换标签页。向左滚动到下一个标签页，向右滚动到上一个标签页。设为 `false` 可关闭这一行为。",
        .full_en =
        \\If `true` (default), then two-finger horizontal scrolling on a touchpad
        \\will switch between tabs. Scrolling left goes to the next tab and
        \\scrolling right goes to the previous tab. Set this to `false` to
        \\disable this behavior.
        \\
        \\Available since 1.4.0.
        ,
        .full_zh =
        \\为 `true`（默认）时，在触控板上用两指横向滚动可切换标签页。向左滚动到下一个标签页，向右滚动到上一个标签页。设为 `false` 可关闭这一行为。
        \\
        \\自 1.4.0 起可用。
        ,
    },
    .{
        .key = .@"gtk-custom-css",
        .en = "Custom CSS files to be loaded.",
        .zh = "要加载的自定义 CSS 文件。",
        .full_en =
        \\Custom CSS files to be loaded.
        \\
        \\GTK CSS documentation can be found at the following links:
        \\
        \\  * https://docs.gtk.org/gtk4/css-overview.html - An overview of GTK CSS.
        \\  * https://docs.gtk.org/gtk4/css-properties.html - A comprehensive list
        \\    of supported CSS properties.
        \\
        \\Launch Ghostty with `env GTK_DEBUG=interactive ghostty` to tweak Ghostty's
        \\CSS in real time using the GTK Inspector. Errors in your CSS files would
        \\also be reported in the terminal you started Ghostty from. See
        \\https://developer.gnome.org/documentation/tools/inspector.html for more
        \\information about the GTK Inspector.
        \\
        \\This configuration can be repeated multiple times to load multiple files.
        \\Prepend a ? character to the file path to suppress errors if the file does
        \\not exist. If you want to include a file that begins with a literal ?
        \\character, surround the file path in double quotes (").
        \\The file size limit for a single stylesheet is 5MiB.
        \\
        \\Available since: 1.1.0
        ,
        .full_zh =
        \\要加载的自定义 CSS 文件。
        \\
        \\GTK CSS 的文档可以在以下链接找到：
        \\
        \\  * https://docs.gtk.org/gtk4/css-overview.html：GTK CSS 概览。
        \\  * https://docs.gtk.org/gtk4/css-properties.html：支持的 CSS 属性的完整列表。
        \\
        \\用 `env GTK_DEBUG=interactive ghostty` 启动 Ghostty，就可以用 GTK Inspector 实时调整 Ghostty 的 CSS。你的 CSS 文件里的错误，也会在你启动 Ghostty 的那个终端里报告出来。关于 GTK Inspector 的更多信息，见 https://developer.gnome.org/documentation/tools/inspector.html。
        \\
        \\这项配置可以重复多次，加载多个文件。在文件路径前加一个 ? 字符，可以在文件不存在时不报错。如果要包含的文件名本身以 ? 字符开头，就用双引号（"）把文件路径包起来。单个样式表的文件大小上限为 5MiB。
        \\
        \\自 1.1.0 起可用。
        ,
    },
    .{ .key = .@"desktop-notifications", .en = "If `true` (default), applications running in the terminal can show desktop notifications using certain escape sequences such as OSC 9 or OSC 777.", .zh = "为 `true`（默认）时，终端里运行的应用可以用某些转义序列（如 OSC 9 或 OSC 777）显示桌面通知。" },
    .{ .key = .@"progress-style", .en = "If `true` (default), applications running in the terminal can show graphical progress bars using the ConEmu OSC 9;4 escape sequence. If `false`, progress bar sequences are silently ignored.", .zh = "为 `true`（默认）时，终端里运行的应用可以用 ConEmu 的 OSC 9;4 转义序列显示图形进度条。为 `false` 时，进度条序列会被静默忽略。" },
    .{
        .key = .@"bold-color",
        .en = "Modifies the color used for bold text in the terminal.",
        .zh = "修改终端里粗体文字所用的颜色。",
        .full_en =
        \\Modifies the color used for bold text in the terminal.
        \\
        \\This can be set to a specific color, using the same format as
        \\`background` or `foreground` (e.g. `#RRGGBB` but other formats
        \\are also supported; see the aforementioned documentation). If a
        \\specific color is set, this color will always be used for the default
        \\bold text color. It will set the rest of the bold colors to `bright`.
        \\
        \\This can also be set to `bright`, which uses the bright color palette
        \\for bold text. For example, if the text is red, then the bold will
        \\use the bright red color. The terminal palette is set with `palette`
        \\but can also be overridden by the terminal application itself using
        \\escape sequences such as OSC 4. (Since Ghostty 1.2.0, the previous
        \\configuration `bold-is-bright` is deprecated and replaced by this
        \\usage).
        \\
        \\Available since Ghostty 1.2.0.
        ,
        .full_zh =
        \\修改终端里粗体文字所用的颜色。
        \\
        \\可以设为一个具体的颜色，格式和 `background` 或 `foreground` 相同（例如 `#RRGGBB`，也支持其他格式；见前面提到的文档）。设了具体颜色时，默认的粗体文字颜色总是用这个颜色，其余的粗体颜色会设为 `bright`。
        \\
        \\也可以设为 `bright`，对粗体文字使用亮色调色板。例如，文字是红色时，粗体会用亮红色。终端调色板用 `palette` 设置，但终端程序自己也可以用 OSC 4 之类的转义序列覆盖它。（自 Ghostty 1.2.0 起，之前的配置 `bold-is-bright` 已弃用，由这种用法取代。）
        \\
        \\自 Ghostty 1.2.0 起可用。
        ,
    },
    .{
        .key = .@"faint-opacity",
        .en = "The opacity level (opposite of transparency) of the faint text. A value of 1 is fully opaque and a value of 0 is fully transparent. A value less than 0 or greater than 1 will be clamped to the nearest valid value.",
        .zh = "暗淡文字的不透明度（透明度的反面）。1 为完全不透明，0 为完全透明。小于 0 或大于 1 的值会被限制到最近的有效值。",
        .full_en =
        \\The opacity level (opposite of transparency) of the faint text. A value of
        \\1 is fully opaque and a value of 0 is fully transparent. A value less than 0
        \\or greater than 1 will be clamped to the nearest valid value.
        \\
        \\Available since Ghostty 1.2.0.
        ,
        .full_zh =
        \\暗淡文字的不透明度（透明度的反面）。1 为完全不透明，0 为完全透明。小于 0 或大于 1 的值会被限制到最近的有效值。
        \\
        \\自 Ghostty 1.2.0 起可用。
        ,
    },
    .{
        .key = .term,
        .en = "This will be used to set the `TERM` environment variable. HACK: We set this with an `xterm` prefix because vim uses that to enable key protocols (specifically this will enable `modifyOtherKeys`), among other features. An option exists in vim to modify this: `:set keyprotocol=ghostty:kitty`, however a bug in the implementation prevents it from working properly. https://github.com/vim/vim/pull/13211 fixes this.",
        .zh = "用于设置 `TERM` 环境变量。取巧做法：我们给它加了 `xterm` 前缀，因为 vim 据此启用按键协议（具体是启用 `modifyOtherKeys`）等功能。vim 里有一个选项可以修改这一点：`:set keyprotocol=ghostty:kitty`，但实现里的一个 bug 使它不能正常工作。https://github.com/vim/vim/pull/13211 修复了这个问题。",
        .full_en =
        \\This will be used to set the `TERM` environment variable.
        \\HACK: We set this with an `xterm` prefix because vim uses that to enable key
        \\protocols (specifically this will enable `modifyOtherKeys`), among other
        \\features. An option exists in vim to modify this: `:set
        \\keyprotocol=ghostty:kitty`, however a bug in the implementation prevents it
        \\from working properly. https://github.com/vim/vim/pull/13211 fixes this.
        \\
        \\On Windows the default is `xterm-256color`: no compiled `xterm-ghostty`
        \\terminfo entry ships there, and a program that looks its `TERM` up -- the
        \\vim that comes with Git for Windows -- finds nothing, does not switch to
        \\the alternate screen, and leaves its whole screen behind when it exits.
        ,
        .full_zh =
        \\用于设置 `TERM` 环境变量。取巧做法：我们给它加了 `xterm` 前缀，因为 vim 据此启用按键协议（具体是启用 `modifyOtherKeys`）等功能。vim 里有一个选项可以修改这一点：`:set keyprotocol=ghostty:kitty`，但实现里的一个 bug 使它不能正常工作。https://github.com/vim/vim/pull/13211 修复了这个问题。
        \\
        \\在 Windows 上，默认值是 `xterm-256color`：那里没有附带编译好的 `xterm-ghostty` terminfo 条目，而一个会去查它的 `TERM` 的程序（Git for Windows 自带的 vim）什么都找不到，不切换到备用屏幕，退出时把整屏内容留在原处。
        ,
    },
    .{ .key = .@"enquiry-response", .en = "String to send when we receive `ENQ` (`0x05`) from the command that we are running. Defaults to an empty string if not set.", .zh = "收到所运行命令发来的 `ENQ`（`0x05`）时发送的字符串。不设置则默认为空字符串。" },
    .{
        .key = .@"async-backend",
        .en = "Configures the low-level API to use for async IO, eventing, etc.",
        .zh = "配置用于异步 IO、事件等的底层 API。",
        .full_en =
        \\Configures the low-level API to use for async IO, eventing, etc.
        \\
        \\Most users should leave this set to `auto`. This will automatically detect
        \\scenarios where APIs may not be available (for example `io_uring` on
        \\certain hardened kernels) and fall back to a different API. However, if
        \\you want to force a specific backend for any reason, you can set this
        \\here.
        \\
        \\Based on various benchmarks, we haven't found a statistically significant
        \\difference between the backends with regards to memory, CPU, or latency.
        \\The choice of backend is more about compatibility and features.
        \\
        \\Available options:
        \\
        \\  * `auto` - Automatically choose the best backend for the platform
        \\    based on available options.
        \\  * `epoll` - Use the `epoll` API
        \\  * `io_uring` - Use the `io_uring` API
        \\
        \\If the selected backend is not available on the platform, Ghostty will
        \\fall back to an automatically chosen backend that is available.
        \\
        \\Changing this value requires a full application restart to take effect.
        \\
        \\This is only supported on Linux, since this is the only platform
        \\where we have multiple options. On macOS, we always use `kqueue`.
        \\
        \\Available since: 1.2.0
        ,
        .full_zh =
        \\配置用于异步 IO、事件等的底层 API。
        \\
        \\大多数用户应该保持 `auto`。它会自动检测某些 API 可能不可用的情况（例如在某些加固过的内核上的 `io_uring`），并退回另一个 API。不过，如果你出于任何原因想强制使用某个后端，可以在这里设置。
        \\
        \\根据各种基准测试，我们没有发现各后端在内存、CPU 或延迟方面有统计上显著的差别。选择后端更多是兼容性和功能方面的事。
        \\
        \\可用选项：
        \\
        \\  * `auto`：根据可用的选项，为平台自动选择最好的后端。
        \\  * `epoll`：使用 `epoll` API
        \\  * `io_uring`：使用 `io_uring` API
        \\
        \\如果选中的后端在平台上不可用，Ghostty 会退回一个自动选择的、可用的后端。
        \\
        \\修改这个值需要完全重启应用才能生效。
        \\
        \\只在 Linux 上支持，因为只有那个平台有多种选择。在 macOS 上，我们总是使用 `kqueue`。
        \\
        \\自 1.2.0 起可用。
        ,
    },
    .{
        .key = .@"auto-update",
        .en = "Control the auto-update functionality of Ghostty. This is only supported on macOS currently, since Linux builds are distributed via package managers that are not centrally controlled by Ghostty.",
        .zh = "控制 Ghostty 的自动更新功能。目前只有 macOS 支持，因为 Linux 版本通过包管理器分发，Ghostty 无法集中控制。",
        .full_en =
        \\Control the auto-update functionality of Ghostty. This is only supported
        \\on macOS currently, since Linux builds are distributed via package
        \\managers that are not centrally controlled by Ghostty.
        \\
        \\Checking or downloading an update does not send any information to
        \\the project beyond standard network information mandated by the
        \\underlying protocols. To put it another way: Ghostty doesn't explicitly
        \\add any tracking to the update process. The update process works by
        \\downloading information about the latest version and comparing it
        \\client-side to the current version.
        \\
        \\Valid values are:
        \\
        \\ * `off` - Disable auto-updates.
        \\ * `check` - Check for updates and notify the user if an update is
        \\   available, but do not automatically download or install the update.
        \\ * `download` - Check for updates, automatically download the update,
        \\   notify the user, but do not automatically install the update.
        \\
        \\If unset, we defer to Sparkle's default behavior, which respects the
        \\preference stored in the standard user defaults (`defaults(1)`).
        \\
        \\Changing this value at runtime works after a small delay.
        ,
        .full_zh =
        \\控制 Ghostty 的自动更新功能。目前只有 macOS 支持，因为 Linux 版本通过包管理器分发，Ghostty 无法集中控制。
        \\
        \\检查或下载更新时，除了底层协议规定的标准网络信息，不会向项目发送任何信息。换句话说：Ghostty 不会在更新过程中刻意加入任何跟踪。更新过程是下载关于最新版本的信息，在本地与当前版本比较。
        \\
        \\有效值：
        \\
        \\ * `off`：停用自动更新。
        \\ * `check`：检查更新，有更新时通知用户，但不自动下载或安装更新。
        \\ * `download`：检查更新，自动下载更新并通知用户，但不自动安装更新。
        \\
        \\不设置时，沿用 Sparkle 的默认行为，它遵从标准用户默认设置（`defaults(1)`）里保存的偏好。
        \\
        \\在运行时修改这个值，稍等片刻后生效。
        ,
    },
    .{
        .key = .@"auto-update-channel",
        .en = "The release channel to use for auto-updates.",
        .zh = "自动更新使用的发布渠道。",
        .full_en =
        \\The release channel to use for auto-updates.
        \\
        \\The default value of this matches the release channel of the currently
        \\running Ghostty version. If you download a pre-release version of Ghostty
        \\then this will be set to `tip` and you will receive pre-release updates.
        \\If you download a stable version of Ghostty then this will be set to
        \\`stable` and you will receive stable updates.
        \\
        \\Valid values are:
        \\
        \\ * `stable` - Stable, tagged releases such as "1.0.0".
        \\ * `tip` - Pre-release versions generated from each commit to the
        \\   main branch. This is the version that was in use during private
        \\   beta testing by thousands of people. It is generally stable but
        \\   will likely have more bugs than the stable channel.
        \\
        \\Changing this configuration requires a full restart of
        \\Ghostty to take effect.
        \\
        \\This only works on macOS since only macOS has an auto-update feature.
        ,
        .full_zh =
        \\自动更新使用的发布渠道。
        \\
        \\默认值和当前运行的 Ghostty 版本的发布渠道一致。如果你下载的是 Ghostty 的预发布版本，这项就是 `tip`，你会收到预发布更新。如果你下载的是稳定版本，这项就是 `stable`，你会收到稳定版更新。
        \\
        \\有效值：
        \\
        \\ * `stable`：稳定的、打了标签的发布，例如 "1.0.0"。
        \\ * `tip`：从 main 分支的每次提交生成的预发布版本。这是数千人在私测期间使用的版本。它一般是稳定的，但很可能比稳定渠道有更多 bug。
        \\
        \\修改这项配置需要完全重启 Ghostty 才能生效。
        \\
        \\只在 macOS 上有效，因为只有 macOS 有自动更新功能。
        ,
    },
};
