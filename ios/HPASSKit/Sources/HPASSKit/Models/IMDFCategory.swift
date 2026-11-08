import Foundation

/// IMDF unit category：扫描后给房间选类别用，规则和 `tools/venue/imdf_convert.py` 一致。
public enum IMDFUnitCategory {
    /// 不可走（imdf_convert 的 NON_WALKABLE）
    public static let nonWalkable: Set<String> = [
        "structure", "column", "shaft", "nonpublic", "opentobelow", "elevator.shaft",
        "mechanical", "electrical", "unenclosedarea.nonpublic", "steps.nonpublic",
    ]
    /// 连接体：电梯 / 扶梯 / 楼梯 / 坡道（imdf_convert 的 CONNECTOR）
    public static let connectors: Set<String> = ["elevator", "escalator", "stairs", "steps", "ramp", "movingwalkway"]
    /// 有名字时导出 occupant 的类别（和 imdf_export.py 的 OCCUPANT_UNIT_CATEGORIES 一致）
    public static let occupantCategories: Set<String> = ["room", "retail", "office", "unspecified"]

    /// 手机上可选的类别（IMDF 规范里的常用项），按常用程度排序
    public static let common: [(id: String, label: String)] = [
        ("room", "房间"), ("walkway", "走廊 / 通道"), ("restroom", "卫生间"),
        ("restroom.female", "女卫生间"), ("restroom.male", "男卫生间"), ("restroom.unisex", "无性别卫生间"),
        ("elevator", "电梯"), ("stairs", "楼梯"), ("escalator", "扶梯"), ("ramp", "坡道"),
        ("lobby", "大堂"), ("conferenceroom", "会议室"), ("office", "办公室"), ("retail", "商铺"),
        ("kitchen", "厨房"), ("storage", "储藏室"), ("parking", "停车场"), ("auditorium", "礼堂"),
        ("classroom", "教室"), ("laboratory", "实验室"), ("library", "图书馆"), ("lounge", "休息区"),
        ("fieldofplay", "运动场地"), ("foodservice", "餐饮"), ("firstaid", "医务室"),
        ("nonpublic", "非公共区域"), ("structure", "结构 / 墙体"), ("opentobelow", "中庭挑空"),
        ("unspecified", "未指定"),
    ]

    public static func label(_ id: String) -> String { common.first { $0.id == id }?.label ?? id }
    public static func isWalkable(_ id: String) -> Bool { !nonWalkable.contains(id.lowercased()) }
    public static func isConnector(_ id: String) -> Bool { connectors.contains(id.lowercased()) }

    /// RoomPlan 的房间类型（iOS 17 `CapturedRoom.Section.Label` 的名字）→ 建议的 IMDF 类别
    public static func suggest(roomPlanSection label: String?) -> String? {
        switch label?.lowercased() {
        case "bathroom": return "restroom"
        case "kitchen": return "kitchen"
        case "livingroom", "diningroom", "bedroom": return "room"
        default: return nil
        }
    }
}
