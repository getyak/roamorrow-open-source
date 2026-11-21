import Foundation

enum TripExamples {
    private static let osaka = TripCity(code: "osaka", name: tripText("example.osaka", "Osaka"), timezone: "Asia/Tokyo")
    private static let kyoto = TripCity(code: "kyoto", name: tripText("example.kyoto", "Kyoto"), timezone: "Asia/Tokyo")
    private static let kobe = TripCity(code: "kobe", name: tripText("example.kobe", "Kobe"), timezone: "Asia/Tokyo")

    static let preview = record("example-japan", tripText("example.japan", "December in Japan"), [
            day("2026-12-12", osaka, [stop("jp-arrive", "13:20", tripText("example.arrive", "Arrive at Kansai Airport"), 90, .transit, 34.4359, 135.2440, locked: true)]),
            day("2026-12-13", osaka, [stop("jp-nakanoshima", "10:30", tripText("example.nakanoshima", "A walk around Nakanoshima"), 60, .outdoor, 34.6924, 135.5079)]),
            day("2026-12-14", kyoto, [
                stop("jp-east", "10:30", tripText("example.east", "A walk through Higashiyama"), 50, .outdoor, 34.9979, 135.7806),
                stop("jp-river", "14:10", tripText("example.river", "Walk along the Kamo River"), 50, .outdoor, 35.0044, 135.7714),
                stop("jp-dinner", "18:00", tripText("example.dinner", "Dinner in Gion"), 80, .indoor, 35.0031, 135.7742, locked: true,
                     note: tripText("example.dinner.note", "Sample reservation for a family dinner"))
            ]),
            day("2026-12-15", kyoto, [stop("jp-market", "12:40", tripText("example.market", "Lunch at Nishiki Market"), 70, .indoor, 35.0051, 135.7648)]),
            day("2026-12-16", kobe, [stop("jp-kobe", "11:00", tripText("example.port", "A walk by Kobe Port"), 80, .outdoor, 34.6820, 135.1888)]),
        ], [
            guide("jp-tea", kyoto, tripText("example.tea", "Tea break in Gion"), 60, .indoor, 35.0036, 135.7735, tripText("example.tea.note", "Sample idea for a quiet break")),
            guide("jp-book", kyoto, tripText("example.museum", "Kyoto International Manga Museum"), 75, .indoor, 35.0117, 135.7589, tripText("example.museum.note", "Indoor option. Check hours before visiting.")),
            guide("jp-coffee", osaka, tripText("example.coffee", "Coffee in Kitahama"), 60, .indoor, 34.6917, 135.5069, tripText("example.coffee.note", "Leave some time to sit and unwind")),
            guide("jp-kobe-museum", kobe, tripText("example.maritime", "Kobe Maritime Museum"), 70, .indoor, 34.6826, 135.1883, tripText("example.maritime.note", "Indoor option near the harbor")),
        ])

    #if DEBUG
    private static let bangkok = TripCity(code: "bkk", name: "曼谷", timezone: "Asia/Bangkok")
    private static let chiangMai = TripCity(code: "cmi", name: "清迈", timezone: "Asia/Bangkok")
    private static let kualaLumpur = TripCity(code: "kul", name: "吉隆坡", timezone: "Asia/Kuala_Lumpur")
    private static let penang = TripCity(code: "pen", name: "槟城", timezone: "Asia/Kuala_Lumpur")

    static let records: [TripRecord] = [
        preview,
        record("example-thailand", "1 月泰国旅行", [
            day("2027-01-16", bangkok, [stop("th-river", "16:20", "昭披耶河边走走", 45, .outdoor, 13.7444, 100.4892)]),
            day("2027-01-17", bangkok, [stop("th-market", "10:00", "曼谷旧城", 85, .outdoor, 13.7526, 100.4942)]),
            day("2027-01-18", chiangMai, [stop("th-gate", "15:00", "塔佩门到古城", 55, .outdoor, 18.7877, 98.9938)]),
            day("2027-01-19", chiangMai, [stop("th-coffee", "11:00", "古城咖啡", 95, .indoor, 18.7896, 98.9856)]),
        ], [
            guide("th-art", bangkok, "曼谷艺术文化中心", 80, .indoor, 13.7467, 100.5302, "半天的室内备选"),
            guide("th-temple", chiangMai, "帕辛寺", 65, .outdoor, 18.7894, 98.9817, "老城散步可顺路加入"),
        ]),
        record("example-malaysia", "2 月马来西亚旅行", [
            day("2027-02-12", kualaLumpur, [stop("my-park", "16:10", "吉隆坡城中城公园", 60, .outdoor, 3.1533, 101.7137)]),
            day("2027-02-13", kualaLumpur, [stop("my-market", "11:00", "中央艺术坊", 65, .indoor, 3.1454, 101.6955)]),
            day("2027-02-14", penang, [stop("my-george", "15:30", "乔治市街巷", 60, .outdoor, 5.4164, 100.3385)]),
            day("2027-02-15", penang, [stop("my-clan", "10:00", "姓周桥", 55, .outdoor, 5.4124, 100.3408)]),
        ], [
            guide("my-art", kualaLumpur, "马来西亚伊斯兰艺术博物馆", 90, .indoor, 3.1410, 101.6890, "想放慢的一天可预留 90 分钟"),
            guide("my-coffee", penang, "乔治市咖啡休息", 55, .indoor, 5.4171, 100.3365, "示例备选 · 街巷行程中间休息"),
        ]),
    ]
    #endif

    private static func record(_ id: String, _ title: String, _ days: [TripDay], _ handbook: [TripGuidePlace]) -> TripRecord {
        TripRecord(id: id, version: 1, plan: TripPlan(title: title, days: days, handbook: handbook),
                   undo: nil, latestSummary: nil, isExample: true)
    }

    private static func day(_ date: String, _ city: TripCity, _ stops: [TripStop]) -> TripDay {
        TripDay(date: date, city: city, stops: stops)
    }

    private static func stop(_ id: String, _ time: String, _ title: String, _ duration: Int, _ activity: TripActivity,
                             _ latitude: Double, _ longitude: Double, locked: Bool = false, note: String? = nil) -> TripStop {
        TripStop(id: id, time: time, title: title, durationMinutes: duration, activity: activity,
                 place: TripPlace(name: title, latitude: latitude, longitude: longitude), locked: locked, note: note)
    }

    private static func guide(_ id: String, _ city: TripCity, _ title: String, _ duration: Int, _ activity: TripActivity,
                              _ latitude: Double, _ longitude: Double, _ note: String) -> TripGuidePlace {
        TripGuidePlace(id: id, cityCode: city.code, title: title, durationMinutes: duration, activity: activity,
                       place: TripPlace(name: title, latitude: latitude, longitude: longitude), note: note, sourceURL: nil)
    }
}
