FROM nginx:1.25-alpine
COPY nginx.conf /etc/nginx/nginx.conf
# 各 location 共用的反代头单独成文件，nginx.conf 通过 include 引用。
COPY metafusion-proxy.conf /etc/nginx/metafusion-proxy.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
