# Governance on-chain (run it yourself)

An issuer can run a general meeting, a dividend, and the share-transfer rules on contracts they deploy and own. Those contracts keep working if InvestHub is offline. InvestHub has no admin key, no pause, and no upgrade role on them.

The source is the public [Investhub-org/Governance](https://github.com/Investhub-org/Governance) repository. This page is a mirror of that kit. The contracts are **unaudited**. Nothing here is an offer, a financial-services licence, or investment advice.

| Page | What it covers |
| --- | --- |
| [Factory](./factory) | One transaction deploys the issuer's set. Addresses are deterministic. The issuer owns it. |
| [Modules](./modules) | Company rules, share terms, acquisition, and recovery. Placeholders are not the PGR or the TVTG. |
| [Meetings](./meetings) | How an issuer convenes an AGM or an EGM and votes, without InvestHub. |
| [Claims](./claims) | How a holder claims a dividend from chain data, without InvestHub. |

Agents that only need to read a meeting, or to prepare an unsigned vote, delegation, or wrap, can use the MCP tools on [Agents & MCP](/agents/mcp). Those tools still require Sign-In with Ethereum and a human signature. They are a client of these contracts, not an owner of them.

::: warning Not investment advice
This is not an offer and not investment advice. Offerings, where they are made, go through a licensed partner (in review). InvestHub does not hold an ECSP licence. The numbers stored as `PLACEHOLDER_*` are software defaults. They are not a reading of the Liechtenstein PGR or the TVTG. A lawyer replaces them before anyone relies on them.
:::
