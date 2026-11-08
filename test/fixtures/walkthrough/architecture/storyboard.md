<!-- Generated from storyboard.json; do not edit -->

# How an order moves

## 1. Order flow (`overview`)

- Duration: 2000 ms
- Screen: screens/overview.html
- Assumption A-01: Orders are written synchronously; side work goes to a queue.
- Node `web`: Web app
- Node `api`: API
- Node `queue`: Job queue
- Node `db`: Postgres (pinned)
- Edge `e1`: web -> api (HTTPS)
- Edge `e2`: api -> db (writes)
- Edge `e3`: api -> queue
- Initial: web, api, e1

| t_ms | op | target |
| --- | --- | --- |
| 300 | add_node | db, queue |
| 400 | connect | e2, e3 |
| 600 | fit_view |  |
| 1400 | highlight | db, e2 |
| 1600 | focus | db |

> An order enters through the web app and lands in Postgres.
