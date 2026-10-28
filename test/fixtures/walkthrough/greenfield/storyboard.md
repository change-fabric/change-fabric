<!-- Generated from storyboard.json; do not edit -->

# Shelfwise: lending in ten seconds

## Hypotheses

- H-01 (role): A volunteer records a loan without help in under ten seconds.
- H-02 (look_and_feel): The new loan appearing at once in the list reassures the volunteer it was saved.

## 1. Record a loan (`lend-book`)

- Duration: 6000 ms
- Screen: screens/lend-book.html
- User goal: Lend a book to a neighbor
- Action: Types the borrower and title, then lends the book
- Emphasis: The default due date saves a step
- Hypotheses: H-01
- Heuristics shown: H1, H6
- Requirement: prd.md#lending

> With Shelfwise, a volunteer records a loan in seconds. Type the borrower, type the title, and the due date is already set two weeks out.

## 2. See every open loan (`loans`)

- Duration: 4000 ms
- Screen: screens/loans.html
- User goal: Confirm the loan was saved
- Action: Opens the loans list and finds the new loan
- Emphasis: The list reflects the loan just recorded
- Starts from: lend-book
- Hypotheses: H-02
- Heuristics shown: H1
- Requirement: prd.md#loans-list
- Assumption A-01: Borrowers and book titles are fictional seed records.

> Every open loan lives in one list. The new loan is already there, and the count is up to date.
