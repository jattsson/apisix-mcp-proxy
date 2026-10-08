FROM gradle:9.7.1-jdk25@sha256:e06837018d077ee7f1218e53499425ca7615702ad58856d980c154caa17eb093 AS build
WORKDIR /build
COPY build.gradle gradle.lockfile Fixture.java ./
RUN gradle --no-daemon classes copyDependencies
FROM gradle:9.7.1-jdk25@sha256:e06837018d077ee7f1218e53499425ca7615702ad58856d980c154caa17eb093
COPY --from=build /build/build /fixture
CMD ["java", "-cp", "/fixture/classes/java/main:/fixture/libs/*", "fixture.Fixture"]
