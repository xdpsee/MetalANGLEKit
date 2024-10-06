  编译步骤
  1. git clone ....
  2. 设置全局代理
      export http_proxy=http://127.0.0.1:????
      export https_proxy=http://127.0.0.1:????
  3. git submodule init
  4. git submodule update
  5. ./setup-angle.sh
  6. ./build-angle.sh [Debug|Release]
