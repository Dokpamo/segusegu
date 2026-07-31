#if DEBUG
import LorepiaKit

enum DevelopmentProviderCatalog {
    static let coreVersion = "lorepia-core-dev-fixtures/0.1.0"

    static let profiles: [ProviderProfile] = [
        ProviderProfile(
            id: "fixture-provider-openai-compatible",
            displayName: "개발용 응답기",
            baseURL: "https://fixtures.invalid/v1",
            model: "lorepia-fixture-chat-v1",
            timeoutSeconds: 30
        ),
        ProviderProfile(
            id: "fixture-provider-local",
            displayName: "로컬 테스트 모델",
            baseURL: "http://127.0.0.1:11434/v1",
            model: "lorepia-fixture-local-7b",
            timeoutSeconds: 45
        ),
        ProviderProfile(
            id: "fixture-provider-long-name",
            displayName: "아주 긴 제공자 이름이 좁은 화면에서 잘리는지 확인하는 개발 프로필",
            baseURL: "https://long-name.fixtures.invalid/openai-compatible/v1",
            model: "lorepia-fixture-model-with-a-deliberately-long-display-value",
            timeoutSeconds: 120
        ),
    ]

    static let credentialValues = [
        "fixture-provider-openai-compatible":
            "lorepia-synthetic-development-credential",
    ]

    static let healthy = HealthStatus(
        coreVersion: coreVersion,
        databaseOpen: true,
        schemaVersion: 1,
        dataRootWritable: true,
        stagingWritable: true,
        recoveryPending: false,
        activeJobs: 0
    )

    static let warning = HealthStatus(
        coreVersion: coreVersion,
        databaseOpen: true,
        schemaVersion: 1,
        dataRootWritable: true,
        stagingWritable: false,
        recoveryPending: true,
        activeJobs: 2
    )
}
#endif
