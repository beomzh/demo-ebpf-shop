FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY gateway-service.csproj .
RUN dotnet restore
COPY Program.cs .
RUN dotnet publish -c Release -o /out --no-restore

# aspnet 이미지는 기본으로 8080 에서 듣는다 (ASPNETCORE_HTTP_PORTS=8080).
# OpenShift 는 임의 UID(그룹 0)로 실행한다. 앱 파일은 root 소유·읽기 전용, 임시파일은 /tmp(emptyDir).
FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=build /out .
EXPOSE 8080
USER 1654
ENTRYPOINT ["dotnet", "gateway-service.dll"]
