# EMSYS — Native Mobile and Desktop Product Specification

## Required Code Conventions

Before writing or refactoring code, read and follow
[docs/code-conventions.md](docs/code-conventions.md).

Use purpose-based names, focused responsibilities, and readable, idiomatic Swift.
Do not name production types after milestones, implementation phases, or prototypes.
Review changed code against these conventions and run the relevant validation
before reporting completion. These rules apply to new code and modifications to
existing code.

## Required Verification Gate

After every code or dependency change, run `./scripts/verify.sh` before moving to
another feature or reporting the increment complete. This checks pinned package
resolution in the normal Xcode workspace, macOS/iPhone/iPad tests and Release
builds. Do not substitute a separate temporary DerivedData build as proof that the
owner's Xcode workspace works. Fix failed resolution, compilation or tests first.

Add regression coverage for changed behavior and recovery paths. When changing
visible behavior, perform the relevant native UI check where access is available;
record any unavailable live-account/device check explicitly. A passing unit suite
does not prove signed login, actual printing or untested UI flows. Verify the open
Xcode project builds after dependency/project changes and before advancing.
Do not alter signing, bundle identifiers or saved project configuration to make
checks pass without the owner's approval. See [Verification](docs/verification.md).

## 1. Purpose

EMSYS is a business management platform with existing web and backend applications.

The objective is to develop modern native applications for Apple and Android devices while preserving established business workflows.

The native applications must support reliable offline operation and synchronization with the existing EMSYS backend.

## 2. Applications

### Apple

Repository: `emsys-swiftui`

Technology: Swift + SwiftUI

Supported platforms:

- iPhone
- iPad
- macOS

Use shared business logic and adaptive native interfaces.

### Android

Repository: `emsys-kotlin`

Technology: Kotlin + Jetpack Compose

Supported platforms:

- Android phones
- Android tablets

Android must remain a native Kotlin application.

Do not use Kotlin Multiplatform or a cross-platform UI framework.

## 3. Application Identity

Application display name:

EMSYS

Preferred application identifiers:

Apple: `com.embarqueros.emsys`

Android: `com.embarqueros.emsys`

Final Apple identifier availability and signing must be verified before physical-device deployment or distribution.

## 4. Existing Systems

### EMSYS Web

Technology: Next.js

Responsibilities:

- Design reference
- User-facing workflows
- Business terminology
- Feature discovery
- Navigation reference

### EMSYS API

Technology: Go/Gin

Responsibilities:

- Authentication
- Authorization
- Business rules
- Validation
- API contracts
- Server persistence
- Multi-tenant boundaries

### Legacy Apple Application

Responsibilities:

- Native feature reference
- Signature capture reference
- PDF generation reference
- Printing reference
- Reusable Apple integrations

The legacy implementation must be reviewed selectively.

It is not the architecture for the new application.

## 5. Product Principles

The applications must be:

- Native
- Offline-first
- Reliable
- Secure
- Maintainable
- Responsive
- Accessible
- Consistent across platforms

Avoid unnecessary architectural complexity.

Prioritize correctness of business operations over decorative interface features.

## 6. Language Requirements

Default language:

Dominican Spanish (`es-DO`)

Additional language:

English (`en`)

Requirements:

- In-app language selector
- Persistent user preference
- Localized navigation
- Localized forms
- Localized validation messages
- Localized status labels
- Localized settings
- Consistent terminology across Apple and Android

Source code and technical documentation remain in English.

## 7. Appearance Requirements

Support:

- Light mode
- Dark mode
- System mode

System mode is the default.

Appearance preference must persist between launches.

Both platforms must support equivalent appearance choices.

## 8. Device Adaptation

### iPhone

Optimize for:

- Touch navigation
- Compact layouts
- Camera workflows
- Signature capture
- Field operations

### iPad

Optimize for:

- Larger forms
- Split navigation
- Multicolumn layouts
- Document previews
- Keyboard and pointer support

### macOS

Optimize for:

- Resizable windows
- Sidebar navigation
- Keyboard shortcuts
- Desktop printing
- File handling
- Multicolumn layouts

### Android Phones and Tablets

Use Jetpack Compose adaptive layouts.

Tablet screens must not simply stretch phone layouts.

## 9. Authentication

Integrate with the existing EMSYS authentication system.

Requirements:

- Secure session storage
- Session restoration
- Token expiration handling
- Logout
- Tenant awareness
- Role-based permissions

Do not invent authentication endpoints or flows.

Offline behavior must respect previously established authorization and security requirements.

## 10. Offline-First Data Architecture

The applications must use local SQLite persistence.

Apple:

GRDB

Android:

Room

The local database is the operational data source for offline-capable workflows.

Network requests should not be required to display already synchronized local records.

Local writes must be durable.

## 11. Synchronization

Synchronization must support:

- Uploading local changes
- Downloading server changes
- Retry after connectivity returns
- Idempotent mutation processing
- Conflict detection
- Error reporting
- Recovery after application termination
- Manual synchronization where useful
- Background synchronization where supported

Background execution is best-effort and subject to operating-system restrictions.

The application must not promise continuous background synchronization.

### Transactional Outbox

When an offline-capable business operation changes local data:

1. Update the local business record.
2. Create the corresponding outbox operation.
3. Commit both changes in one database transaction.
4. Attempt synchronization when appropriate.
5. Mark the operation complete only after server confirmation.

### Conflict Handling

Conflicts must not silently overwrite unsynchronized local work.

The conflict policy must be established for each relevant business operation.

Server-supported versioning or concurrency mechanisms should be used where available.

### API Requirements

Before implementing synchronization, inspect the existing Go API for:

- Stable record identifiers
- Idempotency support
- Record versioning
- Incremental change retrieval
- Deletion handling
- Authentication and tenant context

Document missing capabilities.

Do not invent synchronization contracts.

## 12. Invoice Management

Invoice workflows must be based on the existing EMSYS web application and API.

Expected capabilities include:

- Invoice listing
- Invoice details
- Invoice creation
- Invoice editing
- Local drafts
- Offline changes
- Synchronization status
- Document generation
- Signature association where required

Exact fields, calculations, statuses, and permissions must come from the existing system.

Do not invent invoice business rules.

## 13. Pickup Workflows

Support pickup operations based on existing EMSYS workflows.

Potential capabilities include:

- Assigned pickup lists
- Pickup details
- Status updates
- Photos
- Signatures
- Offline completion
- Synchronization

Confirm actual fields and business rules from the web and API implementations.

## 14. Delivery Workflows

Support delivery operations based on existing EMSYS workflows.

Potential capabilities include:

- Assigned deliveries
- Delivery details
- Status updates
- Proof of delivery
- Photos
- Signatures
- Offline completion
- Synchronization

Confirm actual fields and business rules before implementation.

## 15. Payment Recording

Support payment recording according to the existing backend rules.

Offline payment entry may be supported where safe.

Important distinction:

Recording payment information offline does not mean a payment has been processed or settled.

Server confirmation must determine authoritative payment status.

Never store sensitive payment-card information in the local database.

## 16. Photos and Attachments

Support native image capture and attachment workflows.

Requirements:

- Offline capture
- Local attachment storage
- Durable upload tracking
- Retry after failures
- Association with the correct business record
- Safe cleanup after synchronization

Do not delete attachments that are still required by pending operations.

## 17. Signature Capture

Provide native signature capture.

Requirements:

- Touch and pointer support where appropriate
- Clear and retry actions
- Association with the correct record
- Offline persistence
- Synchronization
- Document integration

Review the legacy Apple signature implementation before selecting the final approach.

## 18. PDF Generation

Support PDF generation using native platform capabilities.

Requirements:

- Offline document generation where feasible
- Consistent business content
- Correct formatting
- Signature integration where required
- Preview
- Printing
- Sharing or export where appropriate

The existing EMSYS document formats are the reference.

## 19. Printing

Support native printing workflows.

Apple:

Use the appropriate iOS, iPadOS, and macOS printing mechanisms.

Android:

Use Android printing APIs.

Printing availability depends on device capabilities and configured printers.

## 20. Local Retention

Supported retention settings:

- 7 days
- 15 days
- 30 days
- 60 days
- 90 days

Users may explicitly mark eligible records:

Retain Locally

Cleanup must never remove:

- Pending changes
- Unsynchronized operations
- Conflicted records
- Explicitly retained records
- Active workflow data
- Required attachments

Retention periods must be applied only when records are eligible for deletion.

## 21. Security and Privacy

Requirements:

- Secure credential storage
- Encrypted transport
- Tenant isolation
- Role-aware features
- Safe logging
- Sensitive data minimization
- Appropriate local data protection

Use Keychain on Apple platforms.

Use appropriate Android secure storage mechanisms.

Follow the backend authorization model.

Do not introduce unsupported client-side permission rules.

## 22. Design System

The native applications must follow the EMSYS brand and established web workflows.

Maintain shared design concepts:

- Colors
- Typography
- Spacing
- Component states
- Validation presentation
- Status indicators
- Navigation terminology

Use native platform interaction patterns.

Apple and Android do not need identical navigation widgets, but the same tasks should remain recognizable and consistent.

## 23. Quality Requirements

Prioritize:

- Predictable behavior
- Recoverable errors
- Clear synchronization status
- Accessibility
- Efficient local queries
- Responsive screens
- Testable business logic
- Reliable database migrations

Avoid blocking the main thread with database or network operations.

## 24. Development Milestones

### Milestone 1 — Apple Foundation

- Verify Xcode project
- Confirm iPhone, iPad, and macOS support
- Establish source organization
- Create adaptive navigation foundation
- Add localization infrastructure
- Add appearance preferences
- Establish initial design tokens
- Add foundational tests

### Milestone 2 — Legacy Apple Review

- Inspect legacy native functionality
- Identify reusable components
- Document modernization opportunities
- Plan signature, PDF, and printing integrations

### Milestone 3 — Web and API Review

- Inspect relevant EMSYS web workflows
- Inspect Go API contracts
- Document business entities
- Identify offline and synchronization requirements
- Identify missing backend capabilities

### Milestone 4 — Authentication

- Implement existing authentication flow
- Secure session storage
- Restore sessions
- Handle expiration and logout
- Respect roles and tenant boundaries

### Milestone 5 — Invoice Vertical Slice

- Establish GRDB persistence
- Implement invoice local models
- Implement invoice listing and details
- Implement approved invoice mutations
- Establish transactional outbox
- Implement initial synchronization
- Test offline recovery

### Milestone 6 — Native Documents

- Signature capture
- PDF generation
- PDF preview
- Printing
- Offline document persistence

### Milestone 7 — Field Operations

- Pickups
- Deliveries
- Photos
- Payment recording
- Retention and cleanup

### Milestone 8 — Android Foundation

- Establish Compose architecture
- Implement localization
- Implement appearance preferences
- Establish adaptive navigation
- Establish Room persistence foundation

### Milestone 9 — Android Feature Parity

- Authentication
- Invoice workflows
- Offline synchronization
- Signatures
- PDFs
- Printing
- Pickups
- Deliveries
- Payments
- Retention

### Milestone 10 — Stabilization

- Cross-platform behavior review
- Performance
- Accessibility
- Security review
- Offline failure testing
- Release preparation

## 25. Implementation Rules

Development must proceed incrementally.

Do not begin a major milestone without approval.

Before implementing a feature:

1. Inspect relevant existing code.
2. Confirm actual business requirements.
3. Review the API contract.
4. Identify offline behavior.
5. Propose the implementation.
6. Wait for approval.

After implementation:

1. Summarize changes.
2. Report tests and build results.
3. Document limitations.
4. Wait for the next milestone.

The Apple application is developed first.

Android follows the approved shared product behavior while using native Android architecture.

Both applications must remain maintainable independently.
