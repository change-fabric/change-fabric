<!-- Generated from storyboard.json; do not edit -->

# Harborline saved trips

## Hypotheses

- H-01 (role): A commuter rebooks a saved trip in one tap without reading instructions.

## 1. Rebook in one tap (`rebook`)

- Duration: 4000 ms
- Screen: screens/home.html
- User goal: Book the usual morning ferry
- Action: Taps rebook on the saved trip
- Hypotheses: H-01
- Heuristics shown: H1, H7
- Requirement: prd.md#saved-trips

> Your usual ferry is waiting on the home screen. One tap on rebook, and the 07:40 to Marrow Quay is booked.

## 2. The ticket is ready (`tickets`)

- Duration: 3000 ms
- Screen: screens/bookings.html
- User goal: Check the ticket before boarding
- Action: Opens tickets and sees the new booking
- Starts from: rebook
- Hypotheses: H-01
- Heuristics shown: H1
- Requirement: prd.md#rebooking
- Assumption A-01: Routes, times, and prices are fictional seed records.

> The ticket is ready before you reach the pier.
