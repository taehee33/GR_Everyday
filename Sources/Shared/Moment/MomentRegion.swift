import CoreLocation

/// The short place name 탐색 filters by (`photos.region`): the 시·도 in Korea ("서울", "제주"),
/// otherwise the country ("일본"). Worked out from the shared coordinates, in Korean.
enum MomentRegion {
    static func name(lat: Double, lon: Double) async -> String? {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon),
                                                                   preferredLocale: Locale(identifier: "ko_KR"))
        guard let mark = marks?.first else { return nil }
        return name(countryCode: mark.isoCountryCode, country: mark.country, area: mark.administrativeArea)
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
