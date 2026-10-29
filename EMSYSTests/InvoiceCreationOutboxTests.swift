import XCTest
@testable import EMSYS

@MainActor
final class InvoiceCreationOutboxTests: XCTestCase {
    func testQueueCommitsFrozenDraftAndOperationAndProtectsPendingWork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let plan = try makePlan()
        let draftID = UUID()
        let operation = try await store.queueInvoiceCreation(draftID: draftID, expectedRevision: nil, plan: plan)
        XCTAssertNil(operation.journalRequest)
        XCTAssertNotNil(operation.invoiceRequest)
        let reopened = try await open(directory)
        let saved = try await reopened.invoiceCreation(draftID: draftID)
        XCTAssertEqual(saved?.invoiceRequest, operation.invoiceRequest)
        let draft = try await reopened.draft(id: draftID)
        XCTAssertEqual(draft?.content, plan.content)
        do {
            _ = try await reopened.saveDraft(id: draftID, content: plan.content, expectedRevision: 1)
            XCTFail("Frozen creation must not be edited")
        } catch InvoiceStore.StoreError.draftChanged { }
        do {
            try await reopened.deleteDraft(id: draftID, expectedRevision: 1)
            XCTFail("Pending work must not be deleted")
        } catch InvoiceStore.StoreError.draftChanged { }
        let anotherDraft = UUID()
        do {
            _ = try await reopened.queueInvoiceCreation(draftID: anotherDraft, expectedRevision: nil, plan: plan)
            XCTFail("An operation UUID cannot belong to two drafts")
        } catch { }
        let rolledBack = try await reopened.draft(id: anotherDraft)
        XCTAssertNil(rolledBack)
        let other = try await InvoiceStore.open(directory: directory, userID: "other", companyID: "company")
        let otherWork = try await other.pendingInvoiceCreations()
        XCTAssertTrue(otherWork.isEmpty)
    }

    func testLostInvoiceResponseRetriesTheExactBodyWithoutPostingPayment() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let operation = try await store.queueInvoiceCreation(draftID: UUID(), expectedRevision: nil, plan: makePlan())
        let (client, session) = try makeClient([.failure(.networkConnectionLost)])
        defer { session.invalidateAndCancel() }
        do {
            try await InvoiceCreationUploader(client: client, store: store).synchronize()
            XCTFail("Lost response must remain pending")
        } catch { }
        CreationProtocol.responses = [.success(invoiceResponse)]
        let reopened = try await open(directory)
        try await InvoiceCreationUploader(client: client, store: reopened).synchronize()
        XCTAssertEqual(CreationProtocol.paths, ["/v1/invoices/sync/create", "/v1/invoices/sync/create"])
        XCTAssertEqual(CreationProtocol.bodies, [operation.invoiceRequest, operation.invoiceRequest].compactMap { $0 })
        let completed = try await reopened.invoiceCreation(draftID: operation.draftID)
        XCTAssertEqual(completed?.state, .completed)
        let invoice = try await reopened.invoice(id: "000000000000000000000003")
        XCTAssertEqual(invoice?.number, "INV-TEST-1")
    }

    func testConfirmedPaymentPersistsBeforeInvoiceAndIsNotPostedAgainAfterReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let operation = try await store.queueInvoiceCreation(draftID: UUID(), expectedRevision: nil, plan: makePlan(payment: "5"))
        XCTAssertNotNil(operation.journalRequest)
        XCTAssertNil(operation.invoiceRequest)
        let (client, session) = try makeClient([.success(receiptResponse), .failure(.networkConnectionLost)])
        defer { session.invalidateAndCancel() }
        do { try await InvoiceCreationUploader(client: client, store: store).synchronize(); XCTFail("Lost invoice response") }
        catch { }
        let reopened = try await open(directory)
        let reopenedOperation = try await reopened.invoiceCreation(draftID: operation.draftID)
        let saved = try XCTUnwrap(reopenedOperation)
        XCTAssertNotNil(saved.invoiceRequest)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(saved.invoiceRequest)) as? [String: Any])
        let invoice = try XCTUnwrap(request["invoice"] as? [String: Any])
        XCTAssertEqual(invoice["number"] as? String, "INV-TEST-1")
        XCTAssertEqual(invoice["autoGenerateNumber"] as? Bool, false)
        XCTAssertEqual(invoice["payment"] as? Double, 5)
        CreationProtocol.responses = [.success(invoiceResponse)]
        try await InvoiceCreationUploader(client: client, store: reopened).synchronize()
        XCTAssertEqual(CreationProtocol.paths, ["/v1/journals/sync", "/v1/invoices/sync/create", "/v1/invoices/sync/create"])
        XCTAssertEqual(CreationProtocol.bodies[1], CreationProtocol.bodies[2])
        let completed = try await reopened.invoiceCreation(draftID: operation.draftID)
        XCTAssertEqual(completed?.state, .completed)
    }

    func testMissingRouteKeepsWorkForExplicitRetryAndNeverFallsBack() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let operation = try await store.queueInvoiceCreation(draftID: UUID(), expectedRevision: nil, plan: makePlan(payment: "5"))
        let (client, session) = try makeClient([.status(404)])
        defer { session.invalidateAndCancel() }
        do { try await InvoiceCreationUploader(client: client, store: store).synchronize(); XCTFail("Needs attention") }
        catch InvoiceCreationUploader.UploadError.attentionRequired { }
        let blocked = try await store.invoiceCreation(draftID: operation.draftID)
        XCTAssertEqual(blocked?.state, .serverUnavailable)
        XCTAssertEqual(CreationProtocol.paths, ["/v1/journals/sync"])
        do { try await InvoiceCreationUploader(client: client, store: store).synchronize(); XCTFail("Blocked work must remain visible") }
        catch InvoiceCreationUploader.UploadError.attentionRequired { }
        XCTAssertEqual(CreationProtocol.paths.count, 1)
        try await store.setInvoiceCreationState(id: operation.id, state: .pending)
        CreationProtocol.responses = [.success(receiptResponse), .success(invoiceResponse)]
        try await InvoiceCreationUploader(client: client, store: store).synchronize()
        XCTAssertEqual(CreationProtocol.bodies[0], CreationProtocol.bodies[1])
    }

    func testAttachmentBytesSurviveReopenAndUploadRetryWithoutRecreatingInvoice() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let draftID = UUID()
        let plan = try makePlan()
        let file = try InvoiceAttachment.prepare(name: "proof.pdf", bytes: Data("%PDF-1.7\nfixture".utf8))
        let saved = try await store.stageAttachment(file.attachment, bytes: file.bytes, draftID: draftID,
            content: plan.content, expectedRevision: nil)
        let frozen = try InvoiceCreationPlan(content: saved.content, branch: plan.branch)
        _ = try await store.queueInvoiceCreation(draftID: draftID, expectedRevision: saved.revision, plan: frozen)
        let beforeConfirmation = try await store.invoiceAttachments(pendingOnly: true)
        XCTAssertTrue(beforeConfirmation.isEmpty)
        let (client, session) = try makeClient([.success(invoiceResponse), .failure(.networkConnectionLost)])
        defer { session.invalidateAndCancel() }
        do { try await InvoiceMutationUploader(client: client, store: store).synchronize(); XCTFail("Lost upload response") }
        catch { }
        let reopened = try await open(directory)
        let operation = try await reopened.invoiceCreation(draftID: draftID)
        XCTAssertEqual(operation?.state, .completed)
        do {
            try await reopened.deleteDraft(id: draftID, expectedRevision: saved.revision + 1)
            XCTFail("Pending attachment must survive cleanup")
        } catch InvoiceStore.StoreError.draftChanged { }
        let receipt = Data("{\"success\":true,\"data\":{\"id\":\"000000000000000000000004\",\"invoiceId\":\"000000000000000000000003\",\"originalName\":\"proof.pdf\",\"mimeType\":\"application/pdf\",\"size\":\(file.bytes.count)}}".utf8)
        CreationProtocol.responses = [.success(receipt)]
        try await InvoiceMutationUploader(client: client, store: reopened).synchronize()
        XCTAssertEqual(CreationProtocol.paths, ["/v1/invoices/sync/create", "/v1/invoices/000000000000000000000003/documents", "/v1/invoices/000000000000000000000003/documents"])
        XCTAssertEqual(CreationProtocol.bodies[1], CreationProtocol.bodies[2])
        XCTAssertTrue(CreationProtocol.bodies[2].contains(file.bytes))
        XCTAssertTrue(String(decoding: CreationProtocol.bodies[2], as: UTF8.self).contains(file.attachment.id.uuidString))
        let attachments = try await reopened.invoiceAttachments(draftID: draftID)
        XCTAssertEqual(attachments.first?.state, .completed)
        let other = try await InvoiceStore.open(directory: directory, userID: "other", companyID: "company")
        let hidden = try await other.invoiceAttachments(draftID: draftID)
        XCTAssertTrue(hidden.isEmpty)
    }

    func testAttachmentImportRollsBackOnStaleDraftAndRemovalIsDurable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let draftID = UUID()
        let content = InvoiceDraft.Content()
        let first = try await store.saveDraft(id: draftID, content: content, expectedRevision: nil)
        let file = try InvoiceAttachment.prepare(name: "photo.png", bytes: Data([137, 80, 78, 71, 13, 10, 26, 10, 1]))
        do {
            _ = try await store.stageAttachment(file.attachment, bytes: file.bytes, draftID: draftID, content: content, expectedRevision: nil)
            XCTFail("Must not overwrite another saved revision")
        } catch InvoiceStore.StoreError.draftChanged { }
        let absent = try await store.invoiceAttachments(draftID: draftID)
        XCTAssertTrue(absent.isEmpty)
        let saved = try await store.stageAttachment(file.attachment, bytes: file.bytes, draftID: draftID,
            content: content, expectedRevision: first.revision)
        let removed = try await store.removeAttachment(id: file.attachment.id, draftID: draftID,
            content: saved.content, expectedRevision: saved.revision)
        XCTAssertEqual(removed.content.attachments, [])
        let reopened = try await open(directory)
        let remaining = try await reopened.invoiceAttachments(draftID: draftID)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertThrowsError(try InvoiceAttachment.prepare(name: "bad\r\n.pdf", bytes: Data("%PDF-1.7".utf8)))
        XCTAssertThrowsError(try InvoiceAttachment.prepare(name: "script.svg", bytes: Data("<svg/>".utf8)))
        XCTAssertThrowsError(try InvoiceAttachment.prepare(name: "huge.pdf", bytes: Data(repeating: 0, count: InvoiceAttachment.maximumSize + 1)))
    }

    func testCopiedDraftGetsIndependentAttachmentIdentityAndRejectsFrozenCreationCopy() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let file = try InvoiceAttachment.prepare(name: "proof.pdf", bytes: Data("%PDF-1.7\nfixture".utf8))
        let saved = try await store.stageAttachment(file.attachment, bytes: file.bytes, draftID: UUID(),
            content: makePlan().content, expectedRevision: nil)
        let copied = try await store.copyDraft(sourceID: saved.id, content: saved.content)
        let copiedFile = try XCTUnwrap(copied.content.attachments?.first)
        XCTAssertNotEqual(copiedFile.id, file.attachment.id)
        XCTAssertEqual(copiedFile.digest, file.attachment.digest)
        let body = try await store.attachmentBody(id: copiedFile.id)
        XCTAssertEqual(body, try copiedFile.multipart(bytes: file.bytes))
        let plan = try InvoiceCreationPlan(content: saved.content, branch: makePlan().branch)
        _ = try await store.queueInvoiceCreation(draftID: saved.id, expectedRevision: saved.revision, plan: plan)
        do {
            _ = try await store.copyDraft(sourceID: saved.id, content: saved.content)
            XCTFail("A frozen submission cannot be copied into a second creation")
        } catch InvoiceStore.StoreError.draftChanged { }
    }

    func testLostPaymentResponseReusesJournalIdentityBeforeCreatingInvoice() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        _ = try await store.queueInvoiceCreation(draftID: UUID(), expectedRevision: nil, plan: makePlan(payment: "5"))
        let (client, session) = try makeClient([.failure(.networkConnectionLost)])
        defer { session.invalidateAndCancel() }
        do { try await InvoiceCreationUploader(client: client, store: store).synchronize(); XCTFail("Lost journal response") }
        catch { }
        CreationProtocol.responses = [.success(receiptResponse), .success(invoiceResponse)]
        let reopened = try await open(directory)
        try await InvoiceCreationUploader(client: client, store: reopened).synchronize()
        XCTAssertEqual(CreationProtocol.paths, ["/v1/journals/sync", "/v1/journals/sync", "/v1/invoices/sync/create"])
        XCTAssertEqual(CreationProtocol.bodies[0], CreationProtocol.bodies[1])
    }

    func testPhoneCreationOmitsUnknownContainerAndPickupAssignmentAfterReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        var content = try makePlan().content
        content.container = nil
        content.pickupSource = nil
        content.pickupEmployee = nil
        content.pickupRoute = nil
        let plan = try InvoiceCreationPlan(content: content, branch: makePlan().branch)
        let operation = try await store.queueInvoiceCreation(draftID: UUID(), expectedRevision: nil, plan: plan)
        let reopened = try await open(directory)
        let restored = try await reopened.invoiceCreation(draftID: operation.draftID)
        XCTAssertEqual(restored?.invoiceRequest, operation.invoiceRequest)
        let body = try XCTUnwrap(restored?.invoiceRequest)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let invoice = try XCTUnwrap(envelope["invoice"] as? [String: Any])
        for key in ["container", "pickupSource", "receivedBy", "route", "pickupEmployee", "officeBranch"] {
            XCTAssertNil(invoice[key], "Unknown operational assignment must be omitted, never fabricated")
        }
        XCTAssertEqual(invoice["autoGenerateNumber"] as? Bool, true)
    }

    func testAttachmentsWaitDurablyForLaterContainerAssignment() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        var content = try makePlan().content
        content.container = nil
        content.pickupSource = nil
        content.pickupEmployee = nil
        let file = try InvoiceAttachment.prepare(name: "proof.pdf", bytes: Data("%PDF-1.7\nfixture".utf8))
        let saved = try await store.stageAttachment(file.attachment, bytes: file.bytes, draftID: UUID(), content: content, expectedRevision: nil)
        let plan = try InvoiceCreationPlan(content: saved.content, branch: makePlan().branch)
        _ = try await store.queueInvoiceCreation(draftID: saved.id, expectedRevision: saved.revision, plan: plan)
        let response = Data(#"{"success":true,"data":{"id":"000000000000000000000003","number":"INV-TEST-1","cost":20,"balance":20,"invoiceDetails":[]}}"#.utf8)
        let (client, session) = try makeClient([.success(response)])
        defer { session.invalidateAndCancel() }
        try await InvoiceMutationUploader(client: client, store: store).synchronize()
        XCTAssertEqual(CreationProtocol.paths, ["/v1/invoices/sync/create"])
        let reopened = try await open(directory)
        let attachments = try await reopened.invoiceAttachments(draftID: saved.id)
        XCTAssertEqual(attachments.first?.state, .awaitingContainer)
        let pending = try await reopened.activeAttachmentCount()
        XCTAssertEqual(pending, 1)
        let body = try await reopened.attachmentBody(id: file.attachment.id)
        XCTAssertEqual(body, try file.attachment.multipart(bytes: file.bytes))
        do {
            try await reopened.deleteDraft(id: saved.id, expectedRevision: saved.revision + 1)
            XCTFail("Waiting attachment cannot be removed by cleanup")
        } catch InvoiceStore.StoreError.draftChanged { }
    }

    func testAwaitingAttachmentsResumeAfterContainerRefreshAndRetryExactUploadAfterReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let original = try makePlan()
        var content = original.content
        content.container = nil
        let prepared = try InvoiceAttachment.prepare(name: "proof.pdf", bytes: Data("%PDF-1.7\nfixture".utf8))
        let legacy = InvoiceAttachment(id: prepared.attachment.id, name: "  proof.pdf  ", mimeType: prepared.attachment.mimeType,
            size: prepared.attachment.size, digest: prepared.attachment.digest)
        let file = (attachment: legacy, bytes: prepared.bytes)
        let draft = try await store.stageAttachment(file.attachment, bytes: file.bytes, draftID: UUID(), content: content, expectedRevision: nil)
        let operation = try await store.queueInvoiceCreation(draftID: draft.id, expectedRevision: draft.revision,
            plan: InvoiceCreationPlan(content: draft.content, branch: original.branch))
        let invoiceID = "000000000000000000000003"
        let unassigned = try JSONDecoder().decode(Invoice.self,
            from: Data(#"{"id":"000000000000000000000003","number":"INV-TEST-1","invoiceDetails":[]}"#.utf8))
        try await store.completeInvoiceCreation(id: operation.id, invoice: unassigned)
        try await store.setAttachmentState(id: file.attachment.id, state: .pending)
        var attachments = try await store.invoiceAttachments(draftID: draft.id)
        XCTAssertEqual(attachments.first?.state, .awaitingContainer, "Manual retry must not bypass assignment")
        let notUsable = try JSONDecoder().decode(Invoice.self,
            from: Data(#"{"id":"000000000000000000000003","number":"INV-TEST-1","container":{"id":0,"name":"No assignment"}}"#.utf8))
        try await store.saveDownloaded([notUsable])
        attachments = try await store.invoiceAttachments(draftID: draft.id)
        XCTAssertEqual(attachments.first?.state, .awaitingContainer)
        let assigned = try JSONDecoder().decode(Invoice.self,
            from: Data(#"{"id":"000000000000000000000003","number":"INV-TEST-1","container":{"id":1,"name":"67-26"},"invoiceDetails":[]}"#.utf8))
        let version = try await store.downloadVersion()
        try await store.saveDownloaded([assigned], ifUnchangedSince: version + 1)
        attachments = try await store.invoiceAttachments(draftID: draft.id)
        XCTAssertEqual(attachments.first?.state, .awaitingContainer, "Rejected stale downloads cannot promote uploads")
        try await store.saveDownloaded([assigned])
        attachments = try await store.invoiceAttachments(draftID: draft.id)
        XCTAssertEqual(attachments.first?.state, .pending)
        let (client, session) = try makeClient([.failure(.networkConnectionLost)])
        defer { session.invalidateAndCancel() }
        do { try await InvoiceAttachmentUploader(client: client, store: store).synchronize(); XCTFail("Lost upload response must remain pending") }
        catch { }
        let reopened = try await open(directory)
        CreationProtocol.responses = [.success(Data("{\"success\":true,\"data\":{\"id\":\"000000000000000000000004\",\"invoiceId\":\"\(invoiceID)\",\"originalName\":\"proof.pdf\",\"mimeType\":\"application/pdf\",\"size\":\(file.bytes.count)}}".utf8))]
        try await InvoiceAttachmentUploader(client: client, store: reopened).synchronize()
        XCTAssertEqual(CreationProtocol.paths, ["/v1/invoices/\(invoiceID)/documents", "/v1/invoices/\(invoiceID)/documents"])
        XCTAssertEqual(CreationProtocol.bodies[0], CreationProtocol.bodies[1])
        XCTAssertEqual(CreationProtocol.bodies[0], try file.attachment.multipart(bytes: file.bytes))
        let completed = try await reopened.invoiceAttachments(draftID: draft.id)
        XCTAssertEqual(completed.first?.state, .completed)
        try await reopened.saveDownloaded([assigned])
        let noReplay = try await reopened.invoiceAttachments(pendingOnly: true)
        XCTAssertTrue(noReplay.isEmpty)
    }

    func testAttachmentNamesMatchAPINormalizationAndRejectInvalidNames() throws {
        let bytes = Data("%PDF-1.7\nfixture".utf8)
        let file = try InvoiceAttachment.prepare(name: "  proof.pdf  ", bytes: bytes)
        XCTAssertEqual(file.attachment.name, "proof.pdf")
        for name in [" ", ".", "..", String(repeating: "a\u{0301}", count: 101) + ".pdf"] {
            XCTAssertThrowsError(try InvoiceAttachment.prepare(name: name, bytes: bytes))
        }
    }

    func testFullSyncUploadsNewlyAssignedAttachmentWithoutAnotherSyncOrInvoiceCreation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let original = try makePlan()
        var content = original.content
        content.container = nil
        let file = try InvoiceAttachment.prepare(name: "photo.png", bytes: Data([137, 80, 78, 71, 13, 10, 26, 10, 1]))
        let draft = try await store.stageAttachment(file.attachment, bytes: file.bytes, draftID: UUID(), content: content, expectedRevision: nil)
        let operation = try await store.queueInvoiceCreation(draftID: draft.id, expectedRevision: draft.revision,
            plan: InvoiceCreationPlan(content: draft.content, branch: original.branch))
        let unassigned = try JSONDecoder().decode(Invoice.self,
            from: Data(#"{"id":"000000000000000000000003","number":"INV-TEST-1","invoiceDetails":[]}"#.utf8))
        try await store.completeInvoiceCreation(id: operation.id, invoice: unassigned)
        let assigned = #"{"id":"000000000000000000000003","number":"INV-TEST-1","container":{"id":1,"name":"67-26"},"invoiceDetails":[]}"#
        let (client, session) = try makeClient([
            .success(Data("{\"success\":true,\"data\":[\(assigned)]}".utf8)),
            .success(Data("{\"success\":true,\"data\":{\"invoice\":\(assigned),\"revision\":\"assigned-revision\"}}".utf8)),
            .success(Data("{\"success\":true,\"data\":{\"id\":\"000000000000000000000004\",\"invoiceId\":\"000000000000000000000003\",\"originalName\":\"photo.png\",\"mimeType\":\"image/png\",\"size\":\(file.bytes.count)}}".utf8))
        ])
        defer { session.invalidateAndCancel() }
        try await InvoiceSynchronizer(client: client, store: store).synchronize()
        XCTAssertEqual(CreationProtocol.paths, ["/v1/invoices", "/v1/invoices/sync/000000000000000000000003", "/v1/invoices/000000000000000000000003/documents"])
        let attachments = try await store.invoiceAttachments(draftID: draft.id)
        XCTAssertEqual(attachments.first?.state, .completed)
        XCTAssertEqual(attachments.first?.invoiceID, unassigned.id)
    }

    func testPaymentCaptureQueuesWithoutCuadreAccessAndUsesAuthenticatedBranch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let editor = InvoiceDraftEditorModel(store: store, currentBranchID: { 1 },
            financialPermission: { [.createInvoice, .recordPayment].contains($0) }, isAuthorized: { true })
        editor.content = try makePlan(payment: "5").content
        XCTAssertNil(editor.content.paymentReview)
        XCTAssertNil(editor.validationIssue(for: .payment))
        await editor.queueCreation()
        XCTAssertTrue(editor.didQueueCreation)
        let operation = try XCTUnwrap(editor.creation)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(operation.journalRequest)) as? [String: Any])
        let entry = try XCTUnwrap(envelope["entry"] as? [String: Any])
        XCTAssertNil(entry["incomeStatementId"])
        XCTAssertNil(entry["incomeStatement"])
        XCTAssertNil(entry["currency"])
        XCTAssertEqual((entry["branch"] as? [String: Any])?["id"] as? Int, 1)
        XCTAssertEqual(entry["amount"] as? Double, 5)
        let reopened = try await open(directory)
        let saved = try await reopened.invoiceCreation(draftID: operation.draftID)
        XCTAssertEqual(saved?.journalRequest, operation.journalRequest)
    }

    func testOldCachedCuadreDoesNotChooseAccountingPeriodForNewSubmission() throws {
        let original = try makePlan()
        var content = original.content
        let otherBranch = AuthenticatedUser.Branch(id: 99, name: "Old branch", code: "OLD")
        content.paymentReview = InvoicePaymentReview(branchID: 99, day: content.date,
            statement: .init(id: 123, businessDate: content.date.apiValue, date: nil, timezone: nil,
                automated: true, branch: otherBranch, currency: "DOP", status: "closed"), downloadedAt: .distantPast)
        let plan = try InvoiceCreationPlan(content: content, branch: original.branch)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: plan.invoiceRequest()) as? [String: Any])
        let invoice = try XCTUnwrap(envelope["invoice"] as? [String: Any])
        XCTAssertNil(invoice["incomeStatement"])
        XCTAssertEqual((invoice["branch"] as? [String: Any])?["id"] as? Int, 1)
        XCTAssertEqual(invoice["payment"] as? Double, 0)
    }

    func testSignatureBase64SurvivesSQLiteSyncAndOnlyMatchesItsConfirmedInvoice() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let original = try makePlan()
        var content = original.content
        let png = try await SignatureDrawing(strokes: [[.init(x: 0.1, y: 0.1), .init(x: 0.8, y: 0.8)]]).pngData()
        content.confirmation = InvoiceDraftConfirmation(contextHash: try InvoiceDraftConfirmation.contextHash(for: content),
            policiesAgreed: true, skipSignature: false)
        content.senderSignature = InvoiceSenderSignature(signerName: content.senderName, data: png.base64EncodedString(), contentType: "image/png")
        let plan = try InvoiceCreationPlan(content: content, branch: original.branch)
        let operation = try await store.queueInvoiceCreation(draftID: UUID(), expectedRevision: nil, plan: plan)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(operation.invoiceRequest)) as? [String: Any])
        let request = try XCTUnwrap(envelope["invoice"] as? [String: Any])
        let signature = try XCTUnwrap(request["senderSignature"] as? [String: Any])
        XCTAssertEqual(signature["data"] as? String, png.base64EncodedString())
        XCTAssertEqual(signature["contentType"] as? String, "image/png")
        let contentJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [String: Any])
        XCTAssertEqual((contentJSON["senderSignature"] as? [String: Any])?["data"] as? String, png.base64EncodedString())
        XCTAssertNil((contentJSON["confirmation"] as? [String: Any])?["signaturePNG"])
        let notConfirmed = try await store.localSenderSignature(invoiceID: "000000000000000000000003")
        XCTAssertNil(notConfirmed)
        let response = Data(#"{"success":true,"data":{"id":"000000000000000000000003","number":"INV-TEST-1","cost":20,"balance":20,"sender":{"id":"000000000000000000000001","name":"Fixture Sender"},"invoiceDetails":[]}}"#.utf8)
        let (client, session) = try makeClient([.success(response)])
        defer { session.invalidateAndCancel() }
        try await InvoiceCreationUploader(client: client, store: store).synchronize()
        let reopened = try await open(directory)
        let restored = try await reopened.localSenderSignature(invoiceID: "000000000000000000000003")
        XCTAssertEqual(restored, png)
        let other = try await reopened.localSenderSignature(invoiceID: "000000000000000000000004")
        XCTAssertNil(other)
        try await reopened.savePrintCompany(.init(id: "company", name: "Fixture Company"))
        let document = try await InvoiceLocalPrinting.generate(invoiceID: "000000000000000000000003", store: reopened, language: "en", printedBy: "Fixture")
        XCTAssertTrue(document.selection.includeSender)
        let saved = try await reopened.latestDocument(invoiceID: document.selection.invoiceID)
        XCTAssertEqual(saved?.pdf, document.pdf)
        let anotherTenant = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "other")
        let isolated = try await anotherTenant.localSenderSignature(invoiceID: "000000000000000000000003")
        XCTAssertNil(isolated)
    }

    func testLegacyQueuedPlanDecodesWithSameSignatureAndRequestIdentities() async throws {
        let original = try makePlan(payment: "5")
        var content = original.content
        let png = try await SignatureDrawing(strokes: [[.init(x: 0.1, y: 0.2), .init(x: 0.9, y: 0.8)]]).pngData()
        content.confirmation = InvoiceDraftConfirmation(contextHash: try InvoiceDraftConfirmation.contextHash(for: content),
            policiesAgreed: true, skipSignature: false)
        content.senderSignature = InvoiceSenderSignature(signerName: content.senderName,
            data: png.base64EncodedString(), contentType: "image/png")
        let plan = try InvoiceCreationPlan(content: content, branch: original.branch)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var legacyContent = try XCTUnwrap(legacy["content"] as? [String: Any])
        legacyContent.removeValue(forKey: "senderSignature")
        var confirmation = try XCTUnwrap(legacyContent["confirmation"] as? [String: Any])
        confirmation["signaturePNG"] = png.base64EncodedString()
        legacyContent["confirmation"] = confirmation
        legacy["content"] = legacyContent
        let decoded = try JSONDecoder().decode(InvoiceCreationPlan.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.invoiceRequestID, plan.invoiceRequestID)
        XCTAssertEqual(decoded.journalRequestID, plan.journalRequestID)
        XCTAssertEqual(decoded.content.senderSignature, plan.content.senderSignature)
        XCTAssertEqual(decoded.content.confirmation?.matches(decoded.content), true)
        let receiptEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: receiptResponse) as? [String: Any])
        let receipt = try JSONDecoder().decode(InvoiceInitialPaymentReceipt.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(receiptEnvelope["data"])))
        let before = try JSONSerialization.jsonObject(with: plan.invoiceRequest(receipt: receipt)) as? NSDictionary
        let after = try JSONSerialization.jsonObject(with: decoded.invoiceRequest(receipt: receipt)) as? NSDictionary
        XCTAssertEqual(before, after)
    }

    func testPickupAssociationSurvivesFrozenOutboxAndReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let original = try makePlan()
        var content = original.content
        content.pickup = InvoicePickupReference(id: 42)
        let plan = try InvoiceCreationPlan(content: content, branch: original.branch)
        let draftID = UUID()
        let queued = try await store.queueInvoiceCreation(draftID: draftID, expectedRevision: nil, plan: plan)
        let reopened = try await open(directory)
        let restored = try await reopened.invoiceCreation(draftID: draftID)
        XCTAssertEqual(restored?.invoiceRequest, queued.invoiceRequest)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(restored?.invoiceRequest)) as? [String: Any])
        let invoice = try XCTUnwrap(body["invoice"] as? [String: Any])
        let pickup = try XCTUnwrap(invoice["pickup"] as? [String: Any])
        XCTAssertEqual(pickup["id"] as? Int, 42)
        content.pickup = InvoicePickupReference(id: 0)
        XCTAssertThrowsError(try InvoiceCreationPlan(content: content, branch: original.branch))
    }

    private func makePlan(payment amount: String? = nil) throws -> InvoiceCreationPlan {
        let customerData = Data(#"{"id":"000000000000000000000001","name":"Fixture Sender","customerType":1,"email":"sender@example.test","IDNumber":"TEST-ID-42"}"#.utf8)
        var content = InvoiceDraft.Content()
        content.date = try XCTUnwrap(InvoiceDate(apiValue: "2026-10-26"))
        content.senderCustomer = try JSONDecoder().decode(InvoiceCustomer.self, from: customerData)
        content.senderWriteSnapshot = try JSONDecoder().decode(InvoiceCustomerWriteSnapshot.self, from: customerData)
        content.senderName = "Fixture Sender"
        content.container = InvoiceContainer(id: 1, name: "67-26", containerNumber: nil)
        content.pickupSource = .office
        content.pickupEmployee = InvoicePickupEmployee(id: 1, name: "Fixture Worker", title: nil, department: nil, active: true,
            branch: .init(id: 1, name: "Fixture Branch", code: "NY", type: "office"))
        content.items = [.init(name: "Fixture box", quantity: "1", unitPrice: "20", labelCount: "1")]
        content.policies = []
        content.paymentRegion = "NY"
        content.payment = InvoiceDraftPayment(mode: amount == nil ? .skip : .record)
        content.payment?.amount = amount ?? "0"
        content.payment?.method = amount == nil ? nil : .cash
        let branch = AuthenticatedUser.Branch(id: 1, name: "Fixture Branch", code: "NY")
        return try InvoiceCreationPlan(content: content, branch: branch)
    }

    private var receiptResponse: Data {
        Data(#"{"success":true,"data":{"id":"000000000000000000000002","transactionType":"INITIAL-PAYMENT","transactionAmount":5,"incomeStatement":{"id":7},"invoice":{"id":"000000000000000000000003","number":"INV-TEST-1","cost":20,"payment":5,"balance":15}}}"#.utf8)
    }
    private var invoiceResponse: Data {
        Data(#"{"success":true,"data":{"id":"000000000000000000000003","number":"INV-TEST-1","date":"2026-10-26","cost":20,"payment":5,"balance":15,"container":{"id":1,"name":"67-26"},"invoiceDetails":[]}}"#.utf8)
    }
    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString) }
    private func open(_ directory: URL) async throws -> InvoiceStore {
        try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
    }
    private func makeClient(_ responses: [CreationProtocol.Response]) throws -> (APIClient, URLSession) {
        CreationProtocol.responses = responses
        CreationProtocol.paths = []
        CreationProtocol.bodies = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CreationProtocol.self]
        let session = URLSession(configuration: configuration)
        let context = UUID()
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.test/v1")), session: session) { _ in
            APICredentials(sessionID: context, userID: "user", companyID: "company", idToken: "fixture-token")
        }
        return (client, session)
    }
}

private final class CreationProtocol: URLProtocol {
    enum Response { case success(Data), status(Int), failure(URLError.Code) }
    nonisolated(unsafe) static var responses: [Response] = []
    nonisolated(unsafe) static var paths: [String] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.paths.append(request.url?.path ?? "")
        if let body = request.httpBody { Self.bodies.append(body) }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var body = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            Self.bodies.append(body)
        }
        guard !Self.responses.isEmpty else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let response = Self.responses.removeFirst()
        if case .failure(let code) = response { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        let status: Int
        let payload: Data
        switch response {
        case .success(let body): status = 201; payload = body
        case .status(let code): status = code; payload = Data()
        case .failure: return
        }
        guard let url = request.url, let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
