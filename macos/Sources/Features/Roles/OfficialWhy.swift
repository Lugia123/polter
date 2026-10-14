import Foundation

/// Why a change to an official role or skill could not be read, by the name
/// the core gives it (`official.WhyCode` in `src/poltergeist/official.zig`),
/// in the person's language (task 1514).
///
/// The core writes its English sentence and, beside it, this name and the
/// one variable part (`reason_code` / `reason_detail`, and the same for
/// `overrides_error`). The banners and states of the role library used to
/// show the English sentence in a Chinese interface.
///
/// `tools/official-why-codes-agree.py` holds these cases to the core's list:
/// a name the core has and this does not would show in English with nothing
/// to say so.
enum OfficialWhy: String, CaseIterable {
    case overridesUnreadable = "overrides_unreadable"
    case overridesNotJson = "overrides_not_json"
    case roleNotObject = "role_not_object"
    case roleUnknownField = "role_unknown_field"
    case roleNotValueAndBase = "role_not_value_and_base"
    case roleNoValue = "role_no_value"
    case roleValueUnreadable = "role_value_unreadable"
    case roleNoBase = "role_no_base"
    case roleBaseUnreadable = "role_base_unreadable"
    case skillNotObject = "skill_not_object"
    case skillNoBase = "skill_no_base"
    case skillBaseNotText = "skill_base_not_text"
    case skillCopyNotThisSkill = "skill_copy_not_this_skill"
    case skillCopyUnrecorded = "skill_copy_unrecorded"

    /// The sentence, with `detail` -- a path, a field, or a file and the
    /// error reading it -- where the sentence has one.
    ///
    /// ⚠️ Each `String(localized:` stays on one line with its literal: the
    /// check that every one has its Chinese reads them that way.
    func text(_ detail: String) -> String {
        let format: String = switch self {
        case .overridesUnreadable: String(localized: "Could not read %@", comment: "角色库：改动文件读不了的原因，%@ 是文件路径和错误")
        case .overridesNotJson: String(localized: "official-overrides.json can't be read as a file of changes.", comment: "角色库：改动文件不是合法的格式")
        case .roleNotObject: String(localized: "What is written for this role is not an object.", comment: "角色库：改动文件里这个角色的条目格式不对")
        case .roleUnknownField: String(localized: "\"%@\" is not a field this version of Polter knows.", comment: "角色库：改动文件里有不认识的字段，%@ 是字段名")
        case .roleNotValueAndBase: String(localized: "\"%@\" is not written as a value and its base.", comment: "角色库：改动文件里某字段格式不对，%@ 是字段名")
        case .roleNoValue: String(localized: "\"%@\" has no value.", comment: "角色库：改动文件里某字段缺值，%@ 是字段名")
        case .roleValueUnreadable: String(localized: "The value of \"%@\" can't be read.", comment: "角色库：改动文件里某字段的值读不了，%@ 是字段名")
        case .roleNoBase: String(localized: "\"%@\" has no base, so it can't be compared with the official version.", comment: "角色库：改动文件里某字段缺基准，%@ 是字段名")
        case .roleBaseUnreadable: String(localized: "The base of \"%@\" can't be read.", comment: "角色库：改动文件里某字段的基准读不了，%@ 是字段名")
        case .skillNotObject: String(localized: "What is written for this skill is not an object.", comment: "角色库：改动文件里这个 skill 的记录格式不对")
        case .skillNoBase: String(localized: "The record for this skill has no base.", comment: "角色库：改动文件里这个 skill 的记录缺基准")
        case .skillBaseNotText: String(localized: "The base recorded for this skill is not text.", comment: "角色库：改动文件里这个 skill 的基准不是文本")
        case .skillCopyNotThisSkill: String(localized: "Your copy at %@ doesn't read as this skill, so the shipped one is in use.", comment: "角色库：官方 skill 的副本读不成这个 skill，%@ 是副本路径")
        case .skillCopyUnrecorded: String(localized: "This copy wasn't saved from Polter, so whether the official text has changed since is not known.", comment: "角色库：官方 skill 的副本不是从 Polter 存的")
        }
        return format.contains("%@") ? String(format: format, detail) : format
    }

    /// What to show: the sentence in the person's language when the core
    /// named it, the core's own words when it did not.
    static func display(code: String?, detail: String?, english: String?) -> String? {
        guard let code, let why = OfficialWhy(rawValue: code) else { return english }
        return why.text(detail ?? "")
    }
}
