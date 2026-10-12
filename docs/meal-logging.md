# Meal logging

Two ways to log a meal, both handled by `pc/agent.py`:

- **On demand:** press C on the standalone Core2 firmware. The current frame
  is analysed (food items, kcal, macros) and logged; hold C to undo.
- **Passive:** run `pc/viewer.py --meal-watch SECONDS`. Every SECONDS it
  runs a cheap "is the wearer eating?" check on the latest frame. On a "yes"
  it runs the full analysis and logs the meal, then waits at least 20 minutes
  before logging again, so one meal isn't logged twice.

Each entry is a photo plus a line in `meal-log/meals.jsonl`:

```json
{"time": "...", "source": "passive", "photo": "meal-20261012-131500.jpg", "is_meal": true,
 "items": [{"name": "...", "portion": "...", "kcal": 0}], "total_kcal": 0, "protein_g": 0,
 "carbs_g": 0, "fat_g": 0, "summary": "..."}
```

## Measured cost and latency

Measured with `muse-spark-1.3` on real glasses frames (Model API prices of
$1.25 per million input and $4.25 per million output tokens):

| Call | Latency | Tokens in/out | Cost |
|---|---|---|---|
| Food check, default reasoning | 9.4 s | 155 / 536 | $0.0025 |
| Food check, `reasoning_effort="minimal"` (used) | 7.7 s | ~155 / 181 | $0.0010 |
| Full meal analysis | 10.6 s | 418 / 634 | $0.0032 |

Muse Spark always reasons, and the API rejects `reasoning_effort="none"`.
With `minimal`, checking every 20 s costs about **$0.17 per hour of
streaming**. A longer interval, or a local food classifier as a first
filter, brings this down further.

Calorie estimates from a photo are rough. Treat them as a diary, not as
nutrition data.
