import CoreLocation
import MapKit

/// Where a shared photo was taken, as 탐색 filters by it, worked out from the shared coordinates
/// in Korean:
/// - region (`photos.region`): the 시·도 in Korea ("서울", "제주"), otherwise the country ("일본").
/// - district (`photos.district`): under it, the 시·군·구 in Korea ("성동구", "수원시"), the
///   prefecture in Japan ("도쿄", "오사카"), otherwise the city ("파리", "타이베이시").
enum MomentRegion {
    struct Place: Equatable {
        var region: String?
        var district: String?
    }

    static func place(lat: Double, lon: Double) async -> Place {
        let location = CLLocation(latitude: lat, longitude: lon)
        let marks = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "ko_KR"))
        guard let mark = marks?.first else { return Place() }
        let region = name(countryCode: mark.isoCountryCode, country: mark.country, area: mark.administrativeArea)
        var district: String?
        if mark.isoCountryCode == "KR" {
            if let city = mark.locality, city != mark.administrativeArea {
                district = city                                   // 수원시, 제주시
            } else if let area = mark.administrativeArea {
                district = await koreanGu(location, after: area)  // 서울특별시 → 성동구
            }
        } else if mark.isoCountryCode == "JP", let prefecture = mark.administrativeArea {
            district = japanese(prefecture)
        } else {
            district = mark.subAdministrativeArea ?? mark.locality
        }
        return Place(region: region, district: district.map { String($0.prefix(30)) })
    }

    /// The 구/군 in a 특별시·광역시 address. CLGeocoder leaves it out ("서울특별시 · 성수동2가");
    /// MapKit's address has it ("서울특별시 성동구 아차산로 100").
    private static func koreanGu(_ location: CLLocation, after area: String) async -> String? {
        guard #available(iOS 26.0, macOS 26.0, *),
              let request = MKReverseGeocodingRequest(location: location) else { return nil }
        request.preferredLocale = Locale(identifier: "ko_KR")
        guard let item = try? await request.mapItems.first,
              let address = item.address?.shortAddress ?? item.address?.fullAddress else { return nil }
        return gu(in: address, after: area)
    }

    /// "서울특별시 성동구 아차산로 100" → "성동구".
    static func gu(in address: String, after area: String) -> String? {
        let words = address.split(separator: " ").map(String.init)
        guard let start = words.firstIndex(of: area) else { return nil }
        return words[(start + 1)...].first { $0.count > 1 && ($0.hasSuffix("구") || $0.hasSuffix("군")) }
    }

    static func name(countryCode: String?, country: String?, area: String?) -> String? {
        let text: String?
        if countryCode == "KR" {
            text = area.map(short) ?? country
        } else {
            text = country ?? countryCode
        }
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return String(text.prefix(20))
    }

    /// "오사카부" → "오사카", "후쿠오카현" → "후쿠오카"; "도쿄", "홋카이도" stay.
    static func japanese(_ prefecture: String) -> String {
        if prefecture == "도쿄도" { return "도쿄" }
        for suffix in ["부", "현"] where prefecture.hasSuffix(suffix) && prefecture.count > 2 {
            return String(prefecture.dropLast())
        }
        return prefecture
    }

    /// Places offered under a country before any photo is there, so the list is never empty.
    static let abroadPresets: [String: [String]] = [
        "일본": ["도쿄", "오사카", "교토", "후쿠오카", "홋카이도", "오키나와", "가나가와", "아이치", "효고", "나라"],
    ]

    /// "서울특별시" → "서울", "충청북도" → "충북", "전북특별자치도" → "전북".
    static func short(_ area: String) -> String {
        if let known = areas[area] { return known }
        for suffix in ["특별자치도", "특별자치시", "특별시", "광역시", "도"] where area.hasSuffix(suffix) && area.count > suffix.count {
            return String(area.dropLast(suffix.count))
        }
        return area
    }

    private static let areas: [String: String] = [
        "서울특별시": "서울", "부산광역시": "부산", "대구광역시": "대구", "인천광역시": "인천",
        "광주광역시": "광주", "대전광역시": "대전", "울산광역시": "울산", "세종특별자치시": "세종",
        "경기도": "경기", "강원도": "강원", "강원특별자치도": "강원",
        "충청북도": "충북", "충청남도": "충남",
        "전라북도": "전북", "전북특별자치도": "전북", "전라남도": "전남",
        "경상북도": "경북", "경상남도": "경남", "제주특별자치도": "제주", "제주도": "제주",
    ]
}
