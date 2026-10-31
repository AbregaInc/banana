import XCTest

/// Gmail's JSON, read into the wire models (MAIL-ENGINE 5.1 and Appendix A).
///
/// **Every JSON here was written by hand from Gmail's documented shapes; none was captured from
/// a live mailbox.** What is asserted is what the models do with those shapes, not what Gmail
/// sends.
///
/// The thing that matters is what a field that did not arrive becomes. Gmail sends different
/// fields for different formats and does not document which (research dossier 2.1, "could not
/// verify" 2), so every property is optional, and a missing one is *unknown*, never empty
/// (invariant 1): a message whose `labelIds` were not read must not look like one with no
/// labels, because the engine removes label memberships on a positive statement only. The tests
/// are the shapes the unverified behaviours could take, each of which has to decode.
final class GmailWireTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - What a read may leave out

    /// `format=minimal`: ids, labels and little else, and no payload at all. Which of the other
    /// fields Gmail adds is unverified, so the same message is read with and without each.
    func testAMinimalMessageWithNoPayloadDecodesAndLeavesWhatItDidNotCarryUnknown() throws {
        let message = try decode(GmailMessage.self, """
            {"id": "17f0a1", "threadId": "17f0a0", "labelIds": ["INBOX", "UNREAD"]}
            """)
        XCTAssertEqual(message.id, "17f0a1")
        XCTAssertEqual(message.threadId, "17f0a0")
        XCTAssertEqual(message.labelIds, ["INBOX", "UNREAD"])
        XCTAssertNil(message.payload)
        XCTAssertNil(message.snippet)
        XCTAssertNil(message.historyId, "a history id that was not sent is not history id 0")
        XCTAssertNil(message.internalDate, "a date that was not sent is not 1970")
        XCTAssertNil(message.sizeEstimate)

        // Its headers are unknown, and say so: nothing was read, so nothing is absent.
        let headers = MessageHeaders(payload: message.payload)
        XCTAssertTrue(headers.fields.isEmpty)
        XCTAssertFalse(headers.isComplete)
    }

    func testAMinimalMessageThatDoesCarryTheFieldsTheDossierIsUnsureOfDecodesToo() throws {
        let message = try decode(GmailMessage.self, """
            {"id": "a", "threadId": "b", "labelIds": ["INBOX"], "snippet": "Hi there",
             "historyId": "1234", "internalDate": "1791277920000", "sizeEstimate": 2310}
            """)
        XCTAssertEqual(message.snippet, "Hi there")
        XCTAssertEqual(message.historyId, 1234)
        XCTAssertEqual(message.internalDate, 1_791_277_920_000)
        XCTAssertEqual(message.sizeEstimate, 2310)
        XCTAssertNil(message.payload)
    }

    /// `messages.list` sends an id and a thread and nothing else; a history record's message
    /// sends those and, on a label record, labels.
    func testAMessageListedByItsIdsAloneHasNothingElse() throws {
        let message = try decode(GmailMessage.self, #"{"id": "a", "threadId": "b"}"#)
        XCTAssertEqual(message.id, "a")
        XCTAssertNil(message.labelIds, "labels that were not sent are not an empty set of labels")
    }

    func testNoLabelsReadAndNoLabelsOnTheMessageAreTwoDifferentThings() throws {
        let none = try decode(GmailMessage.self, #"{"id": "a", "labelIds": []}"#)
        let unread = try decode(GmailMessage.self, #"{"id": "a"}"#)
        XCTAssertEqual(none.labelIds, [], "an empty list was sent: the message has no labels")
        XCTAssertNil(unread.labelIds, "no list was sent: its labels are not known")
    }

    /// `format=metadata`: a payload with headers and a type and no parts and no body.
    func testAMetadataPayloadWithHeadersAndNoPartsOrBodyDecodes() throws {
        let message = try decode(GmailMessage.self, """
            {"id": "a", "threadId": "b", "labelIds": ["INBOX"], "payload": {
              "mimeType": "multipart/alternative",
              "headers": [{"name": "From", "value": "Bob <bob@example.com>"},
                          {"name": "Subject", "value": "Hello"}]}}
            """)
        let payload = try XCTUnwrap(message.payload)
        XCTAssertEqual(payload.mimeType, "multipart/alternative")
        XCTAssertNil(payload.parts, "no parts were sent: the tree was not read, it is not empty")
        XCTAssertNil(payload.body)
        XCTAssertNil(payload.partId)
        XCTAssertEqual(MessageHeaders(payload: payload).value("subject"), "Hello")
    }

    /// The same payload without `mimeType`, and one with only a `partId`.
    func testAPayloadMayLackItsTypeAndItsHeaders() throws {
        let bare = try decode(GmailMessage.self, #"{"id": "a", "payload": {"partId": ""}}"#)
        XCTAssertEqual(bare.payload?.partId, "")
        XCTAssertNil(bare.payload?.mimeType)
        XCTAssertNil(bare.payload?.headers)
    }

    func testEveryTypeDecodesFromAnEmptyObjectWithEveryFieldUnknown() throws {
        XCTAssertEqual(try decode(GmailProfile.self, "{}"), GmailProfile())
        XCTAssertEqual(try decode(GmailLabel.self, "{}"), GmailLabel())
        XCTAssertEqual(try decode(GmailLabelColor.self, "{}"), GmailLabelColor())
        XCTAssertEqual(try decode(GmailHeader.self, "{}"), GmailHeader())
        XCTAssertEqual(try decode(GmailPartBody.self, "{}"), GmailPartBody())
        XCTAssertEqual(try decode(GmailPart.self, "{}"), GmailPart())
        XCTAssertEqual(try decode(GmailMessage.self, "{}"), GmailMessage())
        XCTAssertEqual(try decode(GmailThread.self, "{}"), GmailThread())
        XCTAssertEqual(try decode(GmailMessageRef.self, "{}"), GmailMessageRef())
        XCTAssertEqual(try decode(GmailIDPage.self, "{}"), GmailIDPage())
        XCTAssertEqual(try decode(GmailHistoryChange.self, "{}"), GmailHistoryChange())
        XCTAssertEqual(try decode(GmailHistoryRecord.self, "{}"), GmailHistoryRecord())
        XCTAssertEqual(try decode(GmailHistoryPage.self, "{}"), GmailHistoryPage())
        XCTAssertEqual(try decode(GmailDraft.self, "{}"), GmailDraft())
        XCTAssertEqual(try decode(GmailDraftPage.self, "{}"), GmailDraftPage())
        XCTAssertEqual(try decode(GmailSendAs.self, "{}"), GmailSendAs())
        XCTAssertEqual(try decode(GmailLabelList.self, "{}"), GmailLabelList())
        XCTAssertEqual(try decode(GmailSendAsList.self, "{}"), GmailSendAsList())
    }

    // MARK: - Labels

    func testAnUnknownSystemLabelIsKeptExactlyAsSent() throws {
        let message = try decode(GmailMessage.self, """
            {"id": "a", "labelIds": ["INBOX", "CHAT", "SNOOZED", "CATEGORY_FUTURE", "Label_17"]}
            """)
        XCTAssertEqual(message.labelIds, ["INBOX", "CHAT", "SNOOZED", "CATEGORY_FUTURE", "Label_17"],
                       "labels Gmail adds one day are not ours to drop")
    }

    func testALabelKeepsAnUnknownTypeAndVisibilityAsSent() throws {
        let label = try decode(GmailLabel.self, """
            {"id": "Label_9", "name": "Receipts/2026", "type": "workspace",
             "messageListVisibility": "peek", "labelListVisibility": "labelShowIfUnread"}
            """)
        XCTAssertEqual(label.type, "workspace")
        XCTAssertEqual(label.messageListVisibility, "peek")
        XCTAssertEqual(label.labelListVisibility, "labelShowIfUnread")
    }

    /// `labels.list` sends no counts; `labels.get` does. A zero is a zero, and a count that was
    /// not asked for is not.
    func testALabelCountThatWasNotAskedForIsNotZero() throws {
        let listed = try decode(GmailLabel.self, #"{"id": "INBOX", "name": "INBOX", "type": "system"}"#)
        XCTAssertNil(listed.messagesUnread)
        XCTAssertNil(listed.threadsUnread)
        let counted = try decode(GmailLabel.self, """
            {"id": "INBOX", "messagesTotal": 120, "messagesUnread": 0, "threadsTotal": 80, "threadsUnread": 0,
             "color": {"textColor": "#ffffff", "backgroundColor": "#16a765"}}
            """)
        XCTAssertEqual(counted.messagesUnread, 0)
        XCTAssertEqual(counted.threadsTotal, 80)
        XCTAssertEqual(counted.color, GmailLabelColor(textColor: "#ffffff", backgroundColor: "#16a765"))
    }

    // MARK: - Numbers

    func testHistoryIdAndInternalDateArriveAsDecimalStringsAndAreParsed() throws {
        let message = try decode(GmailMessage.self, """
            {"id": "a", "historyId": "904001", "internalDate": "1791277920000"}
            """)
        XCTAssertEqual(message.historyId, 904_001)
        XCTAssertEqual(message.internalDate, 1_791_277_920_000)
    }

    func testTheLargestHistoryIdParses() throws {
        let message = try decode(GmailMessage.self, #"{"historyId": "18446744073709551615"}"#)
        XCTAssertEqual(message.historyId, UInt64.max)
    }

    /// Whether Gmail ever sends these as JSON numbers is not known; if it or a fake does, they
    /// are read.
    func testHistoryIdAndInternalDateAsJSONNumbersAreReadToo() throws {
        let message = try decode(GmailMessage.self, #"{"id": "a", "historyId": 904001, "internalDate": 1791277920000}"#)
        XCTAssertEqual(message.historyId, 904_001)
        XCTAssertEqual(message.internalDate, 1_791_277_920_000)
    }

    func testAHistoryIdThatDoesNotParseIsNilAndNeverZero() throws {
        for bad in ["", "abc", "12.5", " 5", "5 ", "+5", "-1", "0x10", "1e3", "99999999999999999999",
                    "18446744073709551616", "١٢٣"] {
            let message = try decode(GmailMessage.self, "{\"historyId\": \(jsonString(bad))}")
            XCTAssertNil(message.historyId, "\(bad.debugDescription) is not a history id")
        }
    }

    func testAnInternalDateThatDoesNotParseIsNilAndNeverZero() throws {
        for bad in ["", "yesterday", "1.5", " 7", "0x1", "9223372036854775808", "--5"] {
            let message = try decode(GmailMessage.self, "{\"internalDate\": \(jsonString(bad))}")
            XCTAssertNil(message.internalDate, "\(bad.debugDescription) is not a date")
        }
    }

    /// Mail migrated through the API may have a date before 1970 (dossier 2.2).
    func testAnInternalDateBefore1970IsKept() throws {
        let message = try decode(GmailMessage.self, #"{"internalDate": "-86400000"}"#)
        XCTAssertEqual(message.internalDate, -86_400_000)
    }

    func testCountsSentAsStringsAreReadAndBadOnesAreUnknown() throws {
        let profile = try decode(GmailProfile.self, """
            {"emailAddress": "noor@plan.example", "messagesTotal": "1234", "threadsTotal": "many", "historyId": "77"}
            """)
        XCTAssertEqual(profile.emailAddress, "noor@plan.example")
        XCTAssertEqual(profile.messagesTotal, 1234)
        XCTAssertNil(profile.threadsTotal)
        XCTAssertEqual(profile.historyId, 77)
    }

    // MARK: - What arrives in the wrong shape

    /// One field that is not what it should be must not cost the page or the message it came
    /// with: it is unknown, and the rest is read.
    func testAFieldOfTheWrongTypeIsUnknownAndDoesNotLoseTheMessage() throws {
        let message = try decode(GmailMessage.self, """
            {"id": "a", "threadId": 7, "labelIds": "INBOX", "snippet": ["x"], "sizeEstimate": {"n": 1},
             "payload": "not a part", "historyId": true, "internalDate": [1]}
            """)
        XCTAssertEqual(message.id, "a")
        XCTAssertNil(message.threadId)
        XCTAssertNil(message.labelIds)
        XCTAssertNil(message.snippet)
        XCTAssertNil(message.sizeEstimate)
        XCTAssertNil(message.payload)
        XCTAssertNil(message.historyId)
        XCTAssertNil(message.internalDate)
    }

    func testNullIsUnknownLikeAMissingField() throws {
        let message = try decode(GmailMessage.self, """
            {"id": "a", "labelIds": null, "snippet": null, "historyId": null, "payload": null}
            """)
        XCTAssertNil(message.labelIds)
        XCTAssertNil(message.snippet)
        XCTAssertNil(message.historyId)
        XCTAssertNil(message.payload)
    }

    /// A list that lost one label would look exactly like a message that never had it, and the
    /// engine takes a missing label for a removed one only on a positive statement.
    func testAListWithOneUnreadableElementIsUnknownNotShorter() throws {
        let message = try decode(GmailMessage.self, #"{"id": "a", "labelIds": ["INBOX", 5, "UNREAD"]}"#)
        XCTAssertNil(message.labelIds)
    }

    /// Gmail leaves a page's list out when it is empty, so a list that is *there* and cannot be
    /// read is not "nothing happened": the checkpoint would move over it. The page types throw
    /// (the transport reports `malformed`), and so does a thread's list of messages. Their
    /// elements stay lenient: an entry whose fields are odd is read with those fields unknown.
    func testAListThatIsThereAndCannotBeReadMakesItsPageThrow() {
        XCTAssertThrowsError(try decode(GmailIDPage.self, #"{"messages": [{"id": "a"}, 7], "nextPageToken": "tok"}"#))
        XCTAssertThrowsError(try decode(GmailIDPage.self, #"{"messages": "none"}"#))
        XCTAssertThrowsError(try decode(GmailHistoryPage.self, #"{"history": {"id": "1"}, "historyId": "9"}"#))
        XCTAssertThrowsError(try decode(GmailHistoryPage.self, #"{"history": [1, 2]}"#))
        XCTAssertThrowsError(try decode(GmailDraftPage.self, #"{"drafts": [null]}"#))
        XCTAssertThrowsError(try decode(GmailLabelList.self, #"{"labels": {"id": "x"}}"#))
        XCTAssertThrowsError(try decode(GmailSendAsList.self, #"{"sendAs": "me"}"#))
        XCTAssertThrowsError(try decode(GmailThread.self, #"{"id": "t", "messages": [3]}"#))
    }

    func testAPageWhoseListIsAbsentOrNullIsAPageWithNoneAndItsOtherFieldsAreKept() throws {
        let page = try decode(GmailIDPage.self, #"{"messages": null, "nextPageToken": "tok", "resultSizeEstimate": 201}"#)
        XCTAssertNil(page.messages)
        XCTAssertEqual(page.nextPageToken, "tok")
        XCTAssertEqual(page.resultSizeEstimate, 201)
        XCTAssertNil(try decode(GmailHistoryPage.self, #"{"historyId": "9"}"#).history)
        // Estimates may be unknown. A malformed continuation must never be
        // interpreted as a final page, which would falsely complete enumeration.
        XCTAssertThrowsError(try decode(GmailIDPage.self, #"{"messages": [], "nextPageToken": 5}"#))
        let odd = try decode(GmailIDPage.self, #"{"messages": [], "nextPageToken": null, "resultSizeEstimate": "many"}"#)
        XCTAssertEqual(odd.messages, [])
        XCTAssertNil(odd.nextPageToken)
        XCTAssertNil(odd.resultSizeEstimate)
    }

    func testAnEntryWithOddFieldsInAPageIsStillReadWithThoseFieldsUnknown() throws {
        let page = try decode(GmailIDPage.self, #"{"messages": [{"id": 5, "threadId": "t"}, {"id": "b"}]}"#)
        XCTAssertEqual(page.messages?.count, 2)
        XCTAssertNil(page.messages?.first?.id)
        XCTAssertEqual(page.messages?.first?.threadId, "t")
        XCTAssertEqual(page.messages?.last?.id, "b")
    }

    func testUnknownFieldsAreIgnoredAtEveryLevel() throws {
        let message = try decode(GmailMessage.self, """
            {"id": "a", "classificationLabelValues": [{"x": 1}], "raw": "AAAA", "newThing": {"deep": [1, 2]},
             "payload": {"partId": "0", "future": true,
               "headers": [{"name": "From", "value": "x@y.com", "extra": 1}],
               "body": {"size": 4, "data": "AAAA", "novel": null},
               "parts": [{"partId": "0.0", "mimeType": "text/plain", "surprise": "!"}]}}
            """)
        XCTAssertEqual(message.id, "a")
        XCTAssertEqual(message.payload?.headers?.first?.value, "x@y.com")
        XCTAssertEqual(message.payload?.body?.size, 4)
        XCTAssertEqual(message.payload?.parts?.first?.partId, "0.0")
    }

    func testAnOutermostValueThatIsNotAnObjectThrows() {
        XCTAssertThrowsError(try decode(GmailMessage.self, "[1, 2]"))
        XCTAssertThrowsError(try decode(GmailMessage.self, "\"x\""))
        XCTAssertThrowsError(try decode(GmailMessage.self, "<html>captive portal</html>"))
        XCTAssertThrowsError(try decode(GmailMessage.self, ""))
    }

    // MARK: - The MIME tree

    func testAnAlternativeInsideMixedInsideRelatedDecodesWithEveryPartId() throws {
        let message = try decode(GmailMessage.self, """
            {"id": "a", "payload": {"partId": "", "mimeType": "multipart/mixed", "parts": [
              {"partId": "0", "mimeType": "multipart/related", "parts": [
                {"partId": "0.0", "mimeType": "multipart/alternative", "parts": [
                  {"partId": "0.0.0", "mimeType": "text/plain", "body": {"size": 5, "data": "SGVsbG8"}},
                  {"partId": "0.0.1", "mimeType": "text/html", "body": {"size": 12, "data": "PGI-aGk8L2I-"}}]},
                {"partId": "0.1", "mimeType": "image/png", "filename": "logo.png",
                 "headers": [{"name": "Content-ID", "value": "<logo@example.com>"}],
                 "body": {"size": 900, "attachmentId": "ANGjdJ_x"}}]},
              {"partId": "1", "mimeType": "application/pdf", "filename": "invoice.pdf",
               "body": {"size": 120000, "attachmentId": "ANGjdJ_y"}}]}}
            """)
        let root = try XCTUnwrap(message.payload)
        XCTAssertEqual(root.parts?.map(\.partId), ["0", "1"])
        let related = try XCTUnwrap(root.parts?.first)
        XCTAssertEqual(related.parts?.map(\.mimeType), ["multipart/alternative", "image/png"])
        let alternative = try XCTUnwrap(related.parts?.first)
        XCTAssertEqual(alternative.parts?.map(\.partId), ["0.0.0", "0.0.1"])
        XCTAssertEqual(alternative.parts?.last?.body?.data, "PGI-aGk8L2I-")
        XCTAssertEqual(related.parts?.last?.body?.attachmentId, "ANGjdJ_x")
        XCTAssertNil(related.parts?.last?.body?.data, "a large part has no data: it is fetched by attachment id")
    }

    func testATreeFiftyPartsDeepDecodes() throws {
        let tree = try decode(GmailMessage.self, nestedMessage(depth: 50))
        var depth = 0
        var part = tree.payload
        while let current = part, let child = current.parts?.first { depth += 1; part = child }
        XCTAssertEqual(depth, 50)
    }

    /// A tree nested past what the JSON reader allows is not read; the reader refuses it with an
    /// error rather than recursing, and does not crash. (The walk of P03b limits depth to 20,
    /// but a response must first be read at all. A message this deep decodes to nothing, so
    /// the transport must treat the error as a message it cannot read, not as a failure to
    /// retry for ever.)
    func testATreeNestedPastTheJSONReadersLimitThrowsAndDoesNotCrash() {
        XCTAssertThrowsError(try decode(GmailMessage.self, nestedMessage(depth: 100_000)))
        XCTAssertThrowsError(try decode(GmailMessage.self, nestedMessage(depth: 2_000)))
    }

    // MARK: - Mail's own bound on recursion (L15)

    /// A `GmailPart` deeper than 64 stops the decode by mail's own count, so that what stops a
    /// hostile tree is not a limit somebody else may raise. The root is depth 0.
    func testAPartTreeSixtyFourDeepDecodesAndSixtyFiveStopsTheDecodeWithMailsOwnError() throws {
        XCTAssertEqual(GmailPart.maxDepth, 64)
        let ok = try decode(GmailMessage.self, nestedMessage(depth: 64))
        XCTAssertNotNil(ok.payload)
        XCTAssertThrowsError(try decode(GmailMessage.self, nestedMessage(depth: 65))) { error in
            XCTAssertEqual(error as? GmailDecodeLimit, .partsTooDeep, "mail's own error, not Foundation's")
        }
        // Well inside what the JSON reader allows (about 250 levels): the limit is ours.
        XCTAssertThrowsError(try decode(GmailMessage.self, nestedMessage(depth: 100))) { error in
            XCTAssertEqual(error as? GmailDecodeLimit, .partsTooDeep)
        }
    }

    /// It is not forgiven by the layers that forgive everything else: a message's `payload` and a
    /// thread's messages and a draft's message and a history record's message all let it through.
    func testTheDepthLimitIsNotSwallowedByAnyForgivingLayerAboveIt() throws {
        func part(_ depth: Int) -> String {
            var json = ""
            for _ in 0..<depth { json += #"{"parts": ["# }
            json += "{}"
            for _ in 0..<depth { json += "]}" }
            return json
        }
        // `PART` stands for the tree.
        let templates: [(String, String, String)] = [
            ("message", "GmailMessage", #"{"id": "a", "payload": PART}"#),
            ("thread", "GmailThread", #"{"messages": [{"id": "a", "payload": PART}]}"#),
            ("draft", "GmailDraft", #"{"id": "d", "message": {"payload": PART}}"#),
            ("draft page", "GmailDraftPage", #"{"drafts": [{"message": {"payload": PART}}]}"#),
            ("history", "GmailHistoryPage", #"{"history": [{"messagesAdded": [{"message": {"payload": PART}}]}]}"#),
        ]
        func decodeAny(_ kind: String, _ json: String) throws {
            switch kind {
            case "GmailMessage": _ = try decode(GmailMessage.self, json)
            case "GmailThread": _ = try decode(GmailThread.self, json)
            case "GmailDraft": _ = try decode(GmailDraft.self, json)
            case "GmailDraftPage": _ = try decode(GmailDraftPage.self, json)
            default: _ = try decode(GmailHistoryPage.self, json)
            }
        }
        for (name, kind, template) in templates {
            let tooDeep = template.replacingOccurrences(of: "PART", with: part(70))
            XCTAssertThrowsError(try decodeAny(kind, tooDeep), name) {
                XCTAssertEqual($0 as? GmailDecodeLimit, .partsTooDeep, name)
            }
            // Where the path is longer, a tree of 64 still decodes: only "parts" keys are counted.
            XCTAssertNoThrow(try decodeAny(kind, template.replacingOccurrences(of: "PART", with: part(64))), name)
        }
    }

    private func nestedMessage(depth: Int) -> String {
        var json = #"{"id": "a", "payload": "#
        for _ in 0..<depth { json += #"{"mimeType": "multipart/mixed", "parts": ["# }
        json += #"{"mimeType": "text/plain"}"#
        for _ in 0..<depth { json += "]}" }
        return json + "}"
    }

    // MARK: - The other resources

    func testAThreadHoldsItsMessagesOldestFirstAndAStubHoldsNone() throws {
        let thread = try decode(GmailThread.self, """
            {"id": "t1", "historyId": "55", "messages": [{"id": "m1", "threadId": "t1"}, {"id": "m2", "threadId": "t1"}]}
            """)
        XCTAssertEqual(thread.messages?.map(\.id), ["m1", "m2"])
        XCTAssertEqual(thread.historyId, 55)
        let stub = try decode(GmailThread.self, #"{"id": "t2", "snippet": "x", "historyId": "9"}"#)
        XCTAssertNil(stub.messages, "a thread read without its messages is not an empty thread")
    }

    func testAnIDPageCarriesIdsAndTheEstimateAndTheToken() throws {
        let page = try decode(GmailIDPage.self, """
            {"messages": [{"id": "a", "threadId": "t"}, {"id": "b", "threadId": "t"}],
             "nextPageToken": "08123", "resultSizeEstimate": 2}
            """)
        XCTAssertEqual(page.messages?.map(\.id), ["a", "b"])
        XCTAssertEqual(page.nextPageToken, "08123")
        XCTAssertEqual(page.resultSizeEstimate, 2)
    }

    func testAHistoryRecordKeepsWhichKindOfChangeEachMessageWas() throws {
        let page = try decode(GmailHistoryPage.self, """
            {"history": [
               {"id": "101", "messagesAdded": [{"message": {"id": "m1", "threadId": "t1", "labelIds": ["INBOX", "UNREAD"]}}]},
               {"id": "103", "labelsRemoved": [{"message": {"id": "m1", "threadId": "t1", "labelIds": ["UNREAD"]}, "labelIds": ["INBOX"]}],
                            "labelsAdded": [{"message": {"id": "m2", "threadId": "t2"}, "labelIds": ["STARRED"]}]},
               {"id": "107", "messagesDeleted": [{"message": {"id": "m3", "threadId": "t3"}}]}],
             "historyId": "110"}
            """)
        let records = try XCTUnwrap(page.history)
        XCTAssertEqual(records.map(\.id), [101, 103, 107])
        XCTAssertEqual(records[0].messagesAdded?.first?.message?.labelIds, ["INBOX", "UNREAD"])
        XCTAssertNil(records[0].labelsAdded)
        XCTAssertEqual(records[1].labelsRemoved?.first?.labelIds, ["INBOX"])
        XCTAssertEqual(records[1].labelsRemoved?.first?.message?.labelIds, ["UNREAD"])
        XCTAssertEqual(records[1].labelsAdded?.first?.labelIds, ["STARRED"])
        XCTAssertEqual(records[2].messagesDeleted?.first?.message?.id, "m3")
        XCTAssertNil(page.nextPageToken)
        XCTAssertEqual(page.historyId, 110)
    }

    /// A page of no changes: just the current history id, which is the next checkpoint.
    func testAHistoryPageWithNoRecordsStillCarriesTheCurrentHistoryId() throws {
        let page = try decode(GmailHistoryPage.self, #"{"historyId": "9000"}"#)
        XCTAssertNil(page.history)
        XCTAssertEqual(page.historyId, 9000)
    }

    func testADraftHoldsItsOwnIdAndItsMessage() throws {
        let draft = try decode(GmailDraft.self, """
            {"id": "r-1", "message": {"id": "m9", "threadId": "t9", "labelIds": ["DRAFT"]}}
            """)
        XCTAssertEqual(draft.id, "r-1")
        XCTAssertEqual(draft.message?.id, "m9")
        let page = try decode(GmailDraftPage.self, """
            {"drafts": [{"id": "r-1", "message": {"id": "m9", "threadId": "t9"}}, {"id": "r-2"}], "nextPageToken": "x"}
            """)
        XCTAssertEqual(page.drafts?.map(\.id), ["r-1", "r-2"])
        XCTAssertNil(page.drafts?.last?.message)
    }

    func testASendAsAddressKeepsItsFlags() throws {
        let alias = try decode(GmailSendAs.self, """
            {"sendAsEmail": "noor@plan.example", "displayName": "Noor", "replyToAddress": "",
             "signature": "<b>Noor</b>", "isPrimary": true, "isDefault": true, "verificationStatus": "accepted"}
            """)
        XCTAssertEqual(alias.sendAsEmail, "noor@plan.example")
        XCTAssertEqual(alias.isPrimary, true)
        XCTAssertEqual(alias.isDefault, true)
        XCTAssertEqual(alias.replyToAddress, "", "an empty reply-to was sent: it is empty, not unknown")
        XCTAssertEqual(alias.verificationStatus, "accepted")
        let other = try decode(GmailSendAs.self, #"{"sendAsEmail": "alias@plan.example"}"#)
        XCTAssertNil(other.isPrimary, "a flag that was not sent is not false")
    }

    func testAProfileCarriesTheAccountAndItsPosition() throws {
        let profile = try decode(GmailProfile.self, """
            {"emailAddress": "noor@plan.example", "messagesTotal": 20500, "threadsTotal": 9000, "historyId": "123456"}
            """)
        XCTAssertEqual(profile.emailAddress, "noor@plan.example")
        XCTAssertEqual(profile.messagesTotal, 20_500)
        XCTAssertEqual(profile.threadsTotal, 9_000)
        XCTAssertEqual(profile.historyId, 123_456)
    }

    // MARK: - Writing back, and formats

    /// The fake Gmail and the fixtures write these out, so they must come out as Gmail's own
    /// shapes: the two big numbers as decimal strings, an absent field not at all.
    func testAMessageEncodesToGmailsShapeAndReadsBackEqual() throws {
        let message = GmailMessage(id: "a", threadId: "b", labelIds: ["INBOX"], snippet: "s",
                                   historyId: UInt64.max, internalDate: 1_791_277_920_000, sizeEstimate: 9,
                                   payload: GmailPart(partId: "", mimeType: "text/plain",
                                                      headers: [GmailHeader(name: "From", value: "x@y.com")],
                                                      body: GmailPartBody(size: 6, data: "SGVsbG8u")))
        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["historyId"] as? String, "18446744073709551615")
        XCTAssertEqual(object["internalDate"] as? String, "1791277920000")
        XCTAssertEqual(object["sizeEstimate"] as? Int, 9)
        XCTAssertNil(object["raw"])
        XCTAssertEqual(try JSONDecoder().decode(GmailMessage.self, from: data), message)

        let sparse = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GmailMessage(id: "a")))
        XCTAssertEqual((sparse as? [String: Any])?.keys.sorted(), ["id"], "unknown fields are not written as null")
    }

    func testEveryPageAndRecordReadsBackEqualToWhatWasWritten() throws {
        let page = GmailHistoryPage(
            history: [GmailHistoryRecord(id: 7,
                                         messagesAdded: [GmailHistoryChange(message: GmailMessage(id: "m"))],
                                         labelsRemoved: [GmailHistoryChange(message: GmailMessage(id: "m"),
                                                                            labelIds: ["INBOX"])])],
            nextPageToken: "n", historyId: 99)
        XCTAssertEqual(try JSONDecoder().decode(GmailHistoryPage.self, from: JSONEncoder().encode(page)), page)
        let thread = GmailThread(id: "t", historyId: 4, messages: [GmailMessage(id: "m", historyId: 3)])
        XCTAssertEqual(try JSONDecoder().decode(GmailThread.self, from: JSONEncoder().encode(thread)), thread)
        let profile = GmailProfile(emailAddress: "a@b.com", messagesTotal: 1, threadsTotal: 2, historyId: 3)
        XCTAssertEqual(try JSONDecoder().decode(GmailProfile.self, from: JSONEncoder().encode(profile)), profile)
    }

    /// `header` is Gmail's `metadata`; the others are as they are written.
    func testTheHeaderFormatIsGmailsMetadataFormat() {
        XCTAssertEqual(GmailFormat.minimal.apiValue, "minimal")
        XCTAssertEqual(GmailFormat.header.apiValue, "metadata")
        XCTAssertEqual(GmailFormat.full.apiValue, "full")
    }

    // MARK: - The two envelopes (L9)

    func testTheLabelsEnvelopeCarriesTheLabelsOfLabelsList() throws {
        let list = try decode(GmailLabelList.self, """
            {"labels": [{"id": "INBOX", "name": "INBOX", "type": "system"},
                        {"id": "Label_1", "name": "Receipts", "type": "user", "labelListVisibility": "labelShow"}]}
            """)
        XCTAssertEqual(list.labels?.map(\.id), ["INBOX", "Label_1"])
        XCTAssertEqual(list.labels?.last?.name, "Receipts")
        XCTAssertNil(try decode(GmailLabelList.self, "{}").labels, "no key: nothing was listed, which is not a list of none")
        XCTAssertEqual(try decode(GmailLabelList.self, #"{"labels": []}"#).labels, [])
        XCTAssertEqual(try JSONDecoder().decode(GmailLabelList.self, from: JSONEncoder().encode(list)), list)
    }

    func testTheSendAsEnvelopeCarriesTheAddressesOfSendAsList() throws {
        let list = try decode(GmailSendAsList.self, """
            {"sendAs": [{"sendAsEmail": "noor@plan.example", "isPrimary": true, "isDefault": true, "verificationStatus": "accepted"},
                        {"sendAsEmail": "hello@plan.example", "displayName": "Hello", "signature": "<b>x</b>"}]}
            """)
        XCTAssertEqual(list.sendAs?.map(\.sendAsEmail), ["noor@plan.example", "hello@plan.example"])
        XCTAssertEqual(list.sendAs?.first?.isPrimary, true)
        XCTAssertNil(list.sendAs?.last?.isPrimary)
        XCTAssertNil(try decode(GmailSendAsList.self, "{}").sendAs)
        XCTAssertEqual(try JSONDecoder().decode(GmailSendAsList.self, from: JSONEncoder().encode(list)), list)
    }

    // MARK: - The MIME structure

    /// The whole shape, as appendix A gives it, with every field filled.
    private var wholeStructure: MIMEStructure {
        MIMEStructure(
            root: MIMEStructure.Part(partID: "", mimeType: "multipart/mixed", children: [
                MIMEStructure.Part(partID: "0", mimeType: "text/html", size: 12),
                MIMEStructure.Part(partID: "1", mimeType: "application/pdf", filename: "invoice.pdf",
                                   size: 120_000, attachmentID: "ANGjdJ_y"),
                MIMEStructure.Part(partID: "2", mimeType: "text/calendar", isInline: true),
            ]),
            attachments: [
                MIMEStructure.Attachment(partID: "1", name: "invoice.pdf", mimeType: "application/pdf",
                                         size: 120_000, attachmentID: "ANGjdJ_y"),
                MIMEStructure.Attachment(partID: "2", name: "invite.ics", mimeType: "text/calendar",
                                         size: nil, isInline: true, isInvite: true),
            ],
            htmlPartID: "0", plainPartID: nil,
            invite: MIMEStructure.Invite(partID: "2", method: "REQUEST", uid: "abc@example.org"),
            cut: .depth)
    }

    func testTheMIMEStructureIsATreeWithoutDataAndReadsBackEqual() throws {
        let structure = wholeStructure
        let data = try JSONEncoder().encode(structure)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("\"data\""), "the structure is the tree without its data")
        XCTAssertEqual(try JSONDecoder().decode(MIMEStructure.self, from: data), structure)
    }

    /// The four fields after `attachments` are optional, so a value stored without them decodes:
    /// the value of the first version of the type, which had none of them.
    func testAMIMEStructureStoredWithoutTheLaterFieldsDecodes() throws {
        let stored = """
            {"root": {"partID": "", "mimeType": "text/plain", "isInline": false, "children": []},
             "attachments": [{"partID": "1", "name": "a.pdf", "mimeType": "application/pdf", "size": 9,
                              "isInline": false, "isInvite": false}]}
            """
        let structure = try decode(MIMEStructure.self, stored)
        XCTAssertNil(structure.htmlPartID)
        XCTAssertNil(structure.plainPartID)
        XCTAssertNil(structure.invite)
        XCTAssertNil(structure.cut, "nil: the tree is whole")
        XCTAssertEqual(structure.attachments.first?.size, 9)
    }

    /// Gmail gave no size for a part: it is not a file of no bytes.
    func testAnAttachmentWithNoSizeHasNoSizeAndNotZero() throws {
        let attachment = try decode(MIMEStructure.Attachment.self, """
            {"partID": "1", "name": "a.pdf", "mimeType": "application/pdf", "isInline": false, "isInvite": false}
            """)
        XCTAssertNil(attachment.size)
        XCTAssertEqual(MIMEStructure.Attachment(partID: "1", name: "a", mimeType: "x/y").size, nil)
        let sized = MIMEStructure.Attachment(partID: "1", name: "a", mimeType: "x/y", size: 0)
        XCTAssertEqual(sized.size, 0, "an attachment that is known to be empty is not the same")
        XCTAssertNotEqual(sized, MIMEStructure.Attachment(partID: "1", name: "a", mimeType: "x/y"))
    }

    func testTheCutReasonsAndTheInviteAreKeptAsGiven() throws {
        for cut in [MIMEStructure.Cut.depth, .parts] {
            var structure = wholeStructure
            structure.cut = cut
            let back = try JSONDecoder().decode(MIMEStructure.self, from: JSONEncoder().encode(structure))
            XCTAssertEqual(back.cut, cut)
        }
        XCTAssertEqual(MIMEStructure.Cut.depth.rawValue, "depth")
        XCTAssertEqual(MIMEStructure.Cut.parts.rawValue, "parts")
        XCTAssertEqual(wholeStructure.invite, MIMEStructure.Invite(partID: "2", method: "REQUEST", uid: "abc@example.org"))
        XCTAssertNil(MIMEStructure.Invite(partID: "2").method)
        XCTAssertNil(MIMEStructure.Invite(partID: "2").uid)
    }

    // MARK: - Helpers

    private func jsonString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [])) ?? Data()
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
