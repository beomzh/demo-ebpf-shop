FROM docker.io/library/ruby:3.3-slim
# Ruby 3.x 는 WEBrick 을 기본 포함하지 않으므로 gem 으로 설치한다 (순수 Ruby, 네이티브 빌드 없음)
RUN gem install webrick -v 1.8.2 --no-document
WORKDIR /app
COPY --chmod=644 app.rb .
EXPOSE 8080
# OpenShift 는 임의 UID(그룹 0)로 실행한다
USER 10001
CMD ["ruby", "app.rb"]
