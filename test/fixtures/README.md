# API status fixture

`failed-status.json` records the response to `GET /v1/releases/{id}` from the
intake API with a synthetic account and release. Its `failure` text comes
from the API's shared failure copy. The server used an in-memory queue and
synthetic authorization; no live service or customer data was used.

The message-free test removes `failure` from this response to exercise the
Action's fallback for a failed release with no customer text.
