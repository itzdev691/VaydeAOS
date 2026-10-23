# OpenAI Sign in with ChatGPT local SDK

Unmodified `packages/local/src` and `packages/local/test` from
https://github.com/openai/sign-in-with-chatgpt-devkit
at commit `0a36fefeb913055c8c7a1a29b63d82b96b2e841a`.

The SDK is private on npm, so its source is vendored and its dependencies are
pinned in the helper's package-lock.json. Preserve LICENSE and the upstream
third-party notices. The DevKit license permits noncommercial use; commercial
use requires separate rights from OpenAI. VaydeAOS bridge code is independently
authored and communicates with the SDK through its public interface.
