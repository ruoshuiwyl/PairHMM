CODE_DIR = src

.PHONY: project_code

project_code:
	$(MAKE) -C $(CODE_DIR)

clean:
	$(MAKE) -C $(CODE_DIR) clean

test:
	@./pairhmm < test_data/tiny.in | paste - test_data/tiny.out  | awk 'BEGIN {m = 0; n = NR} {a = $$2-$$1; a = a < 0? -a: a; if (a > m) {m = a; n = NR} } END { printf("max error %g at line %d\n", m, n)} '

check:
	valgrind --leak-check=yes ./pairhmm test_data/tiny.in > /dev/null