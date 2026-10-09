import Foundation

@main
struct HomeroomDetailChecks {
    @MainActor static func main() async throws {
        let context = DetailContext(yearId: "year", classId: "class", date: "2026-10-07", from: "2026-08-01", to: "2027-06-01")
        let empty: [String: Any] = ["rows": [], "showContacts": false]
        let roster = try HomeroomDetailDecoder.roster(empty)
        precondition(roster.rows.isEmpty)
        precondition(HomeroomDetailDecoder.matchesStudent(name: "Nguyễn Đặng", code: "S01", search: " nguyen dang "))
        precondition(HomeroomDetailDecoder.matchesStudent(name: "Nguyễn Đặng", code: "S01", search: "s01"))
        precondition(!HomeroomDetailDecoder.matchesStudent(name: "Nguyễn Đặng", code: "S01", search: "no match"))
        precondition(HomeroomDetailDecoder.matchesStudent(name: "Nguyễn Đặng", code: "S01", search: ""))
        precondition(HomeroomDetailDecoder.matchesStudent(name: "Nguyễn Đặng", code: "S01", search: "   "))
        for payload: [String: Any] in [["rows": [], "showContacts": "false"], [:]] {
            do { _ = try HomeroomDetailDecoder.roster(payload); fatalError("Malformed roster accepted") } catch {}
        }
        do { _ = try HomeroomDetailDecoder.history(["days": [], "corrections": "bad"]); fatalError("Malformed history accepted") } catch {}
        let day: [String: Any] = ["_id": "day", "studentId": "student", "classId": "class", "attendanceDate": "2026-10-07", "rawObservation": "late", "disposition": "none", "effectiveStatus": "late"]
        let history = try HomeroomDetailDecoder.history(["days": (0..<501).map { index in var row = day; row["_id"] = "day\(index)"; return row }, "corrections": []])
        precondition(history.days.count == 501 && history.corrections.isEmpty)
        var invalid = day
        invalid["effectiveStatus"] = "unknown"
        do { _ = try HomeroomDetailDecoder.history(["days": [invalid], "corrections": []]); fatalError("Unknown status accepted") } catch {}
        let fake = DetailFake()
        let store = HomeroomDetailStore(operations: fake, context: context)
        await store.load()
        precondition(store.classData != nil)
        store.studentId = "student"
        await store.load()
        precondition(store.studentData != nil)
        fake.denied = true
        await store.load()
        precondition(store.classData == nil && store.studentData == nil && store.error != nil)
        fake.denied = false
        await store.load()
        precondition(store.studentData != nil && store.error == nil)
        fake.block = true
        let stale = Task { await store.load() }
        while fake.continuation == nil { await Task.yield() }
        store.context = DetailContext(yearId: "year", classId: "class", date: "2026-10-06", from: context.from, to: context.to)
        store.studentId = nil
        await store.load()
        fake.continuation?.resume()
        await stale.value
        precondition(store.studentData == nil && store.classData?.daily.date == "2026-10-06")
        var calls: [(String, [String: Any])] = []
        let repository = HomeroomDetailRepository { path, args in
            calls.append((path, args))
            return fixture(path, date: context.date)
        }
        let loadedClass = try await repository.loadClass(context)
        precondition(!loadedClass.daily.canCorrect)
        precondition(calls.map { $0.0 } == ["homeroomClasses:getScoped", "students:listByClass", "studentAttendance:listDailyClass"])
        precondition(Set(calls[0].1.keys) == ["classId", "date"])
        precondition(Set(calls[1].1.keys) == ["classId", "date", "includeSensitiveContacts"])
        precondition(calls[1].1["includeSensitiveContacts"] as? Bool == false)
        precondition(Set(calls[2].1.keys) == ["classId", "attendanceDate"])
        precondition(calls[2].1["attendanceDate"] as? String == context.date)
        calls = []
        let loadedStudent = try await repository.loadStudent(context, studentId: "student")
        precondition(!loadedStudent.profile.showContacts && !loadedStudent.profile.permissions.canEditContacts)
        precondition(calls.map { $0.0 } == ["students:getScoped", "studentAttendance:getStudentHistory"])
        precondition(Set(calls[0].1.keys) == ["studentId", "includeSensitiveContacts"])
        precondition(Set(calls[1].1.keys) == ["studentId", "from", "to"])
        precondition(calls[1].1["from"] as? String == context.from && calls[1].1["to"] as? String == context.to)
        for path in ["homeroomClasses:getScoped", "students:listByClass", "studentAttendance:listDailyClass", "students:getScoped", "studentAttendance:getStudentHistory"] {
            var queried: [String] = []
            var revoked = false
            let forbidden = HomeroomDetailRepository { requested, _ in
                queried.append(requested)
                if revoked && requested == path { throw ConvexException(code: "HOMEROOM_SCOPE_FORBIDDEN") }
                return fixture(requested, date: context.date)
            }
            let blocked = HomeroomDetailStore(operations: forbidden, context: context)
            if path == "students:getScoped" || path == "studentAttendance:getStudentHistory" { blocked.studentId = "student" }
            await blocked.load()
            precondition(blocked.classData != nil || blocked.studentData != nil)
            revoked = true
            await blocked.load()
            precondition(blocked.classData == nil && blocked.studentData == nil && blocked.error != nil)
            precondition(queried.last == path)
        }
        let wrongDate = HomeroomDetailRepository { path, _ in fixture(path, date: "2026-10-06") }
        do { _ = try await wrongDate.loadClass(context); fatalError("Wrong date accepted") } catch {}
        do { _ = try await repository.loadStudent(context, studentId: "wrong-id"); fatalError("Wrong student accepted") } catch {}
        let invalidRange = DetailContext(yearId: context.yearId, classId: context.classId, date: context.date, from: context.to, to: context.from)
        do { _ = try await repository.loadStudent(invalidRange, studentId: "student"); fatalError("Inverted range accepted") } catch {}
        let nullDaily = try HomeroomDetailDecoder.daily(dailyFixture(day: NSNull()))
        precondition(nullDaily.rows.single?.day == nil && nullDaily.rows.count == 1)
        var missingDaily = dailyFixture(day: NSNull())
        var missingRow = (missingDaily["rows"] as! [[String: Any]])[0]
        missingRow.removeValue(forKey: "day")
        missingDaily["rows"] = [missingRow]
        do { _ = try HomeroomDetailDecoder.daily(missingDaily); fatalError("Missing day accepted") } catch {}
        var unknown = day
        unknown["rawObservation"] = "unknown"
        unknown["disposition"] = "pending"
        unknown["effectiveStatus"] = "no_data"
        let unknownDaily = try HomeroomDetailDecoder.daily(dailyFixture(day: unknown))
        precondition(unknownDaily.rows[0].day?.effectiveStatus == "no_data")
        let corrections = try HomeroomDetailDecoder.history(["days": [], "corrections": [["_id": "correction", "attendanceDayId": "day", "studentId": "student", "attendanceDate": "2026-10-07", "previousDisposition": "pending", "nextDisposition": "excused", "previousEffectiveStatus": "absent_pending", "nextEffectiveStatus": "absent_excused", "reasonCode": "leave", "note": "Có phép", "actorUserId": "teacher", "at": 1791356400000]]])
        precondition(corrections.corrections.count == 1 && corrections.corrections[0].note == "Có phép" && corrections.corrections[0].nextEffectiveStatus == "absent_excused")
        var malformed = false
        let malformedRepository = HomeroomDetailRepository { path, _ in malformed ? [:] : fixture(path, date: context.date) }
        let malformedStore = HomeroomDetailStore(operations: malformedRepository, context: context)
        await malformedStore.load()
        precondition(malformedStore.classData != nil)
        malformed = true
        await malformedStore.load()
        precondition(malformedStore.classData == nil && malformedStore.studentData == nil && malformedStore.error != nil && !malformedStore.loading)
        let cancellationGate = QueryGate()
        var cancelledCalls: [String] = []
        let cancelledRepository = HomeroomDetailRepository { path, _ in
            cancelledCalls.append(path)
            await cancellationGate.wait()
            return fixture(path, date: context.date)
        }
        let cancelledTask = Task { try await cancelledRepository.loadClass(context) }
        while cancellationGate.continuation == nil { await Task.yield() }
        cancelledTask.cancel()
        cancellationGate.continuation?.resume()
        do { _ = try await cancelledTask.value; fatalError("Cancellation ignored") } catch {}
        precondition(cancelledCalls == ["homeroomClasses:getScoped"])
        print("PASS L2 strict decode, exact query contracts, negative access at all five RPCs, history 501/no synthetic cap, denied refresh/retry, stale student/date, identity/range rejection, explicit null/unknown no_data")
    }

    static func fixture(_ path: String, date: String) -> [String: Any] {
        switch path {
        case "homeroomClasses:getScoped":
            return ["class": ["_id": "class", "schoolYearId": "year", "code": "10A", "name": "Lớp 10A", "status": "active"], "schoolYear": ["_id": "year", "name": "Năm học"], "assignments": [], "currentTeacherName": "", "rosterCount": 1, "permissions": ["canManage": false, "canImportAttendance": false, "canCorrect": false, "canEditContacts": false]]
        case "students:listByClass":
            return ["rows": [["enrollment": ["_id": "enrollment", "startDate": "2026-08-01", "rosterNumber": 1], "student": ["_id": "student", "studentCode": "S01", "fullName": "Học sinh", "studentPhone": "must-not-cache"], "guardians": []]], "showContacts": false]
        case "studentAttendance:listDailyClass":
            return ["date": date, "rows": [], "published": false, "archived": false, "canCorrect": false, "schoolDay": ["isSchoolDay": true, "kind": "school_day", "outsideYear": false]]
        case "students:getScoped":
            return ["student": ["_id": "student", "studentCode": "S01", "fullName": "Học sinh", "status": "active", "studentPhone": "must-not-cache"], "enrollments": [], "guardians": [], "showContacts": false, "permissions": ["canManage": false, "canEditContacts": false]]
        case "studentAttendance:getStudentHistory": return ["days": [], "corrections": []]
        default: fatalError("Unexpected RPC \(path)")
        }
    }

    static func dailyFixture(day: Any) -> [String: Any] {
        ["date": "2026-10-07", "rows": [["enrollment": ["_id": "enrollment"], "student": ["_id": "student", "studentCode": "S01", "fullName": "Học sinh"], "day": day]], "published": false, "archived": false, "canCorrect": false, "schoolDay": ["isSchoolDay": true, "kind": "school_day", "outsideYear": false]]
    }
}

private extension Array { var single: Element? { count == 1 ? first : nil } }

@MainActor private final class QueryGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
}

@MainActor private final class DetailFake: HomeroomDetailOperations {
    var denied = false
    var block = false
    var continuation: CheckedContinuation<Void, Never>?
    func loadClass(_ context: DetailContext) async throws -> ClassDetail {
        if denied { throw ConvexException(code: "HOMEROOM_SCOPE_FORBIDDEN") }
        return try ClassDetail(
            scoped: HomeroomDetailDecoder.scoped(["class": ["_id": context.classId, "schoolYearId": context.yearId, "code": "10A", "name": "Lớp 10A", "status": "active"], "schoolYear": ["_id": context.yearId, "name": "Năm học"], "assignments": [], "currentTeacherName": "", "rosterCount": 0, "permissions": ["canManage": false, "canImportAttendance": false, "canCorrect": false, "canEditContacts": false]]),
            roster: HomeroomDetailDecoder.roster(["rows": [], "showContacts": false]),
            daily: HomeroomDetailDecoder.daily(["date": context.date, "rows": [], "published": false, "archived": false, "canCorrect": false, "schoolDay": ["isSchoolDay": true, "kind": "school", "outsideYear": false]])
        )
    }
    func loadStudent(_ context: DetailContext, studentId: String) async throws -> StudentDetail {
        if block { await withCheckedContinuation { continuation = $0 } }
        if denied { throw ConvexException(code: "HOMEROOM_SCOPE_FORBIDDEN") }
        return try StudentDetail(profile: HomeroomDetailDecoder.profile(["student": ["_id": studentId, "studentCode": "S01", "fullName": "Học sinh", "status": "active"], "enrollments": [], "guardians": [], "showContacts": false, "permissions": ["canManage": false, "canEditContacts": false]]), history: HomeroomDetailDecoder.history(["days": [], "corrections": []]))
    }
}
