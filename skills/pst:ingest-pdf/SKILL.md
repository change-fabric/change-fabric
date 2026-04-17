---
name: pst:ingest-pdf
description: Ingest a PDF from disk into the current repo as a structured markdown file
argument-hint: "/absolute/path/to/file.pdf"
allowed-tools: Read, Write, Edit, Bash, Grep, Glob
---

# Ingest PDF

Ingest a PDF (email, letter, invoice, contract, or other artifact) into the current repo as a structured markdown file.

## Input

$ARGUMENTS

The argument is the **absolute file path** to a PDF file on disk.

## Procedure

### Step 1: Read the PDF

Use the Read tool to read the PDF file at the provided path. For large PDFs (>10 pages), read in chunks using the `pages` parameter.

### Step 2: Determine output location

Look at the current repo's directory structure to find the best place to put this file. Common patterns:

- `.context/issues/` - correspondence, email threads, call notes
- `.context/invoices/` - invoices
- `.context/sows/` - statements of work, contracts
- `.context/specs/` - technical specifications
- `.context/brand-guides/` - brand and style references
- `docs/` - general documentation

If a `.context/` directory exists with relevant subdirectories, prefer that structure. Otherwise, use `docs/` or whatever convention the repo already uses. If no clear convention exists, default to `.context/` and create the appropriate subdirectory.

### Step 3: Classify the document

Determine what kind of artifact this is based on its content. Use the classification to pick the right subdirectory and filename:

| Type                          | Subdirectory    | Filename pattern       |
| ----------------------------- | --------------- | ---------------------- |
| Email thread / correspondence | `issues/`       | `YYYY-MM-DD-<slug>.md` |
| Invoice                       | `invoices/`     | `YYYY-MM-DD-<slug>.md` |
| Statement of Work / contract  | `sows/`         | `YYYY-MM-DD-<slug>.md` |
| Spec / technical document     | `specs/`        | `YYYY-MM-DD-<slug>.md` |
| Brand guide / style reference | `brand-guides/` | `YYYY-MM-DD-<slug>.md` |
| Other                         | `issues/`       | `YYYY-MM-DD-<slug>.md` |

Use today's date unless the document itself contains a more relevant date (e.g., an invoice date, email date).

The slug should be a short, lowercase, hyphenated descriptor (e.g., `tom-invoice-feb-mar`, `sow-002-analytics`).

### Step 4: Convert to markdown

Transform the PDF content into clean markdown following these conventions:

- **Frontmatter header**: every file starts with a level-1 heading that describes the document, followed by metadata fields:
  - `**Status:**` - Active, Resolved, Paid, etc.
  - `**Date:**` - the document's primary date
  - `**Source:**` - original filename or description of where it came from
  - `**Type:**` - Email, Invoice, SOW, Spec, etc.
  - Add other relevant metadata fields as appropriate (From, To, Subject, etc.)

- **Structure**: preserve the logical structure of the original document. Use headings, tables, and lists as appropriate. For email threads, format each message with sender, date, and quoted content.

- **Fidelity**: preserve all substantive content. Do not summarize or condense - transcribe the full text. Minor formatting cleanup is fine (fixing OCR artifacts, normalizing whitespace).

- **Sensitive data**: keep financial figures, names, and contact info intact unless the user explicitly requests redaction.

### Step 5: Write the file

Write the markdown file to the determined output location. Create subdirectories if needed.

### Step 6: Update docs index (if applicable)

If the repo has a `CLAUDE.md` with a docs index section, add a one-line entry pointing to the new file. If the repo has no docs index convention, skip this step.

### Step 7: Report

Tell the user:

- Where the file was saved
- What type it was classified as
- A one-line summary of the content
