- Sources/Invoices/List.swift: the page size is read from the request and never capped, so one call can ask for
  every invoice. Cap it.
- Tests/InvoiceListTests.swift: nothing covers an empty last page.

VERDICT: FIX